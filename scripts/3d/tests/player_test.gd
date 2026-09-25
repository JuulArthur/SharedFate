extends Node3D

## WP3b test: the ported player on the arena layout, driven through a scripted
## sequence against three stub enemies. Prints `PLAYER OK`, or the first failing
## check with its values as `PLAYER FAIL: ...`, then quits.
##
##   godot --headless --path . res://scenes/3d/tests/player_test.tscn --quit-after 900
##
## The steps follow the WP3b brief: weapon and soul damage, free shifting in
## exploration, the body, weapon, hand and overhead anchor of each soul (WP9),
## one shift per turn, melee with the contact delay, the rogue's
## bolt landing after its flight time, the two mage spells with the frost snare
## cooldown, the knight's three reaction outcomes with the 2D damage maths, and
## XP levelling. Contract: docs/3d-port-contracts.md, sections 5.1, 5.2, 11, 12.

const STUB_ENEMY_SCRIPT: GDScript = preload("res://scripts/3d/stubs/stub_enemy_3d.gd")

const CAMERA_SIZE_M := 14.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

## A spot on the arena floor that the baked navmesh must cover.
const MAP_PROBE := Vector3(0.0, 0.0, 2.5)
## Beat between steps so a hit-stop from the last hit is over before the next
## timing is measured.
const STEP_PAUSE_SECONDS := 0.2
## A SceneTreeTimer created mid-frame counts that frame's delta, and the health
## watcher only looks once per frame, so a contact can read up to about a frame
## early. Well under the 100 ms delay it discriminates.
const TIMING_TOLERANCE_MS := 25
## Upper bound on a bolt's flight, generous for frame jitter.
const BOLT_SLACK_MS := 300

const ENEMY_DAMAGE := 12
const FAR_MELEE_M := 3.0
const FAR_THROW_M := 13.0

# WP9 bodies per soul, in Soul.Kind order: the body node under Player/Model,
# its main mesh, the weapon it holds in the right hand and any weapon that
# stays in the model.
const BODY_NODES: Array[String] = ["Knight", "Rogue", "Mage"]
const BODY_MESHES: Array[String] = ["Knight_Body", "Rogue_Body", "Mage_Body"]
const HELD_WEAPONS: Array[String] = ["Sword", "Dagger_R", "Staff"]
const OFF_HAND_WEAPONS: Array[String] = ["", "Dagger_L", ""]
const HAND_TOLERANCE_M := 0.05
# WP1: OverheadAnchor 0.25 m above the top of the head.
const OVERHEAD_CLEARANCE_M := 0.25
const OVERHEAD_TOLERANCE_M := 0.05
# The archetype animations turn the holder about the hand's local X, so a
# weapon's long axis must stay in the body's forward/up plane: its sideways
# (local X) component stays under this.
const MAX_SIDEWAYS_AXIS := 0.1
const WEAPON_ANIMATIONS: Array[StringName] = [
	Item.ARCHETYPE_MELEE_SLASH, Item.ARCHETYPE_CAST_STAFF, Item.ARCHETYPE_RANGED_BOW]
const ANIMATION_SAMPLES: Array[float] = [0.0, 0.06, 0.12, 0.15, 0.18, 0.26, 0.32, 0.4, 0.45, 0.55]

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var player: Player3D = $Player

var _targets: Array[CharacterBody3D] = []
var _soul_changes := 0
var _hit_msec := -1
var _watch_id := 0
var _reported := false


func _ready() -> void:
	# Headless runs the main loop as fast as it can; the cap keeps timers and
	# physics on a real clock so the contact and flight timings mean something.
	Engine.max_fps = 60
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	CombatFx.set_world_projector(func(p: Variant) -> Vector2: return camera.unproject_position(p as Vector3))
	player.soul_changed.connect(func(_soul: Soul) -> void: _soul_changes += 1)

	_targets = [
		_spawn_target("TargetA", Vector3(1.0, 0.0, 0.0)),
		_spawn_target("TargetB", Vector3(-6.0, 0.0, 6.0)),
		_spawn_target("TargetC", Vector3(-8.0, 0.0, -8.0)),
	]

	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()


func _exit_tree() -> void:
	# The autoload outlives the scene; leave it in its 2D state.
	CombatFx.set_world_projector(Callable())
	CombatFx.set_shake_target(null)


func _setup_camera() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE_M
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true
	var look_at_point := GroundMath.flatten(player.global_position, 1.0)
	var back := Vector3(0.0, 0.0, CAMERA_DISTANCE)
	back = back.rotated(Vector3.RIGHT, deg_to_rad(CAMERA_PITCH_DEG))
	back = back.rotated(Vector3.UP, deg_to_rad(CAMERA_YAW_DEG))
	camera.global_position = look_at_point + back
	camera.look_at(look_at_point, Vector3.UP)


## A stub enemy built in code: group `enemies`, layer 2, 200 HP. The brief asks
## for `aggro_range = 0.0`, but in the stub 0 means "chase from anywhere" (the
## 2D convention), so the targets are also put in turn mode, where the stub
## never acts on its own.
func _spawn_target(target_name: String, at: Vector3) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = target_name
	body.set_script(STUB_ENEMY_SCRIPT)
	body.collision_layer = 2
	body.collision_mask = 9
	body.add_to_group("enemies")
	body.set("max_health", 200)
	body.set("aggro_range", 0.0)

	var box := BoxShape3D.new()
	box.size = Vector3(0.9, 1.0, 0.9)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0.0, 0.5, 0.0)
	body.add_child(shape)

	var box_mesh := BoxMesh.new()
	box_mesh.size = box.size
	var mesh := MeshInstance3D.new()
	mesh.name = "MeshInstance3D"
	mesh.mesh = box_mesh
	mesh.position = shape.position
	body.add_child(mesh)

	add_child(body)
	body.global_position = at
	body.call("set_turn_based_combat", true)
	return body


func _on_bake_finished() -> void:
	await _wait_for_navigation_map()
	await _run()


## The baked mesh only reaches the navigation map on a later server sync; until
## it does, map queries answer with the origin. Waits for the map to report a
## point near a spot that is known to be walkable.
func _wait_for_navigation_map() -> void:
	var map := get_world_3d().navigation_map
	for _i in range(60):
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, MAP_PROBE)
		if GroundMath.ground_distance(closest, MAP_PROBE) < 0.5:
			return
	push_error("[player_test] the navigation map never picked up the baked mesh")


func _run() -> void:
	var steps: Array[Callable] = [
		_step_weapon,
		_step_free_shifting,
		_step_bodies,
		_step_turn_shifting,
		_step_melee,
		_step_throw,
		_step_spells,
		_step_reactions,
		_step_xp,
	]
	var failure := ""
	for step in steps:
		failure = await _run_step(step)
		if not failure.is_empty():
			break
		await _pause(STEP_PAUSE_SECONDS)
	_report(failure)


func _run_step(step: Callable) -> String:
	var result: Variant = await step.call()
	return str(result)


func _report(failure: String) -> void:
	if _reported:
		return
	_reported = true
	if failure.is_empty():
		print("PLAYER OK")
	else:
		print("PLAYER FAIL: %s" % failure)
	get_tree().quit()


# --- Helpers ----------------------------------------------------------------------

func _pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _health_of(target: CharacterBody3D) -> int:
	return int(target.get("health"))


func _place(target: CharacterBody3D, at: Vector3) -> void:
	target.call("snap_to", at)


## Records the wall-clock moment `target` first loses health, from the next
## frame on. Started without `await` so it runs beside the attack it watches;
## only the newest watcher may write the result.
func _watch_health(target: CharacterBody3D, before: int) -> void:
	_watch_id += 1
	var my_id := _watch_id
	_hit_msec = -1
	while is_instance_valid(target) and _health_of(target) == before:
		await get_tree().process_frame
	if my_id == _watch_id:
		_hit_msec = Time.get_ticks_msec()


## The watcher only looks at the start of a frame, so after an attack resolves
## it needs one more frame to record the hit it just missed.
func _let_watcher_catch_up() -> void:
	for _i in range(3):
		if _hit_msec >= 0:
			return
		await get_tree().process_frame


func _shift(kind: Soul.Kind) -> bool:
	return player.shift_to(int(kind))


# --- Steps ------------------------------------------------------------------------

## 1. Iron Sword auto-equipped; damage per soul; range in metres.
func _step_weapon() -> String:
	await _pause(0.05)
	var weapon := player.get_equipped_weapon()
	if weapon == null or weapon.id != &"iron_sword":
		return "weapon: expected the Iron Sword auto-equipped, got %s" % (weapon.id if weapon != null else "nothing")
	if player.get_active_soul().kind != Soul.Kind.KNIGHT:
		return "weapon: the body should start as the knight"
	var knight_damage := player.get_melee_damage()
	if knight_damage != 20:
		return "weapon: knight melee damage %d, expected 20" % knight_damage
	if not _shift(Soul.Kind.ROGUE):
		return "weapon: shift_to(rogue) refused in exploration"
	var rogue_damage := player.get_melee_damage()
	if rogue_damage != 27:
		return "weapon: rogue melee damage %d, expected 27" % rogue_damage
	if not _shift(Soul.Kind.MAGE):
		return "weapon: shift_to(mage) refused in exploration"
	var mage_damage := player.get_melee_damage()
	if mage_damage != 12:
		return "weapon: mage melee damage %d, expected 12" % mage_damage
	var reach := player.get_melee_range()
	if not is_equal_approx(reach, 1.2):
		return "weapon: melee range %.3f m, expected 1.2" % reach
	return ""


## 2. Exploration shifting is free and unlimited; soul_changed fires each time.
func _step_free_shifting() -> String:
	await _pause(0.05)
	_soul_changes = 0
	var order: Array[Soul.Kind] = [Soul.Kind.KNIGHT, Soul.Kind.ROGUE, Soul.Kind.MAGE, Soul.Kind.KNIGHT]
	for kind in order:
		if not _shift(kind):
			return "free shifting: shift_to(%s) returned false in exploration" % Soul.kind_title(kind)
		if player.get_active_soul().kind != kind:
			return "free shifting: active soul is %s after shifting to %s" \
				% [player.get_active_soul().title, Soul.kind_title(kind)]
	if _soul_changes != order.size():
		return "free shifting: soul_changed emitted %d times, expected %d" % [_soul_changes, order.size()]
	if player.get_shifts_left() != 1 or not player.can_shift():
		return "free shifting: get_shifts_left() %d / can_shift() %s outside combat, expected 1 / true" \
			% [player.get_shifts_left(), str(player.can_shift())]
	return ""


## 2b. Bodies per soul (WP9): after each shift exactly the soul's body is
## visible, the soul's own weapon is on EquippedWeaponMesh (the glb's copy
## hidden), HandPoint and OverheadAnchor sit at that body's empties, and the
## weapon hangs (blades) or stands (staff) in the swing plane through the attack
## animations. The knight is checked first as the body shown at _ready.
func _step_bodies() -> String:
	await _pause(0.05)
	var bodies := player.soul_bodies
	if bodies == null:
		return "bodies: Player/Model is not a SoulBodies3D"
	var order: Array[Soul.Kind] = [Soul.Kind.KNIGHT, Soul.Kind.ROGUE, Soul.Kind.MAGE, Soul.Kind.KNIGHT]
	for kind in order:
		if player.get_active_soul().kind != kind and not _shift(kind):
			return "bodies: shift_to(%s) refused in exploration" % Soul.kind_title(kind)
		# Let the 0.15 s scale punch finish before measuring against the body.
		await _pause(SoulBodies3D.SHIFT_PUNCH_SECONDS + 0.1)
		var failure := _check_body(bodies, int(kind))
		if not failure.is_empty():
			return "bodies (%s): %s" % [Soul.kind_title(kind), failure]
		failure = _check_weapon_axis(int(kind))
		if not failure.is_empty():
			return "bodies (%s): %s" % [Soul.kind_title(kind), failure]
	return ""


func _check_body(bodies: SoulBodies3D, kind: int) -> String:
	var expected := bodies.get_node_or_null(BODY_NODES[kind]) as Node3D
	if expected == null:
		return "no %s body under Player/Model" % BODY_NODES[kind]
	if bodies.get_active_body() != expected or bodies.get_active_kind() != kind:
		return "the active body is %s, expected %s" % [bodies.get_active_body(), expected.name]
	var visible_bodies: Array[String] = []
	for body_name in BODY_NODES:
		var body := bodies.get_node_or_null(body_name) as Node3D
		if body != null and body.visible:
			visible_bodies.append(body_name)
	if visible_bodies.size() != 1 or visible_bodies[0] != BODY_NODES[kind]:
		return "visible bodies %s, expected only %s" % [str(visible_bodies), BODY_NODES[kind]]
	if expected.process_mode == Node.PROCESS_MODE_DISABLED:
		return "the visible body has its processing disabled"
	if not expected.scale.is_equal_approx(Vector3.ONE):
		return "the body's scale is %s after the shift punch, expected (1, 1, 1)" % expected.scale

	var original := expected.find_child(HELD_WEAPONS[kind], true, false) as MeshInstance3D
	if original == null:
		return "the %s model has no %s mesh" % [BODY_NODES[kind], HELD_WEAPONS[kind]]
	if original.visible:
		return "the model's own %s is still visible" % HELD_WEAPONS[kind]
	var weapon := player.equipped_weapon_mesh
	if weapon == null or weapon.mesh == null:
		return "EquippedWeaponMesh has no mesh"
	if weapon.mesh != original.mesh:
		return "EquippedWeaponMesh carries %s, expected the %s mesh %s" % [weapon.mesh, HELD_WEAPONS[kind], original.mesh]
	if not weapon.visible:
		return "EquippedWeaponMesh is hidden with the Iron Sword equipped"
	var weapons := bodies.get_weapon_meshes()
	if weapons.is_empty() or weapons[0] != original:
		return "get_weapon_meshes() does not start with the held %s" % HELD_WEAPONS[kind]
	if not OFF_HAND_WEAPONS[kind].is_empty():
		var off_hand := expected.find_child(OFF_HAND_WEAPONS[kind], true, false) as MeshInstance3D
		if off_hand == null or not off_hand.visible:
			return "the off-hand %s is missing or hidden" % OFF_HAND_WEAPONS[kind]
		if not weapons.has(off_hand):
			return "get_weapon_meshes() does not list the off-hand %s" % OFF_HAND_WEAPONS[kind]

	var body_hand := expected.find_child("HandPoint", true, false) as Node3D
	if body_hand == null or bodies.get_hand_point() != body_hand:
		return "get_hand_point() is not the %s model's HandPoint" % BODY_NODES[kind]
	var hand_gap := player.hand_point.global_position.distance_to(body_hand.global_position)
	if hand_gap > HAND_TOLERANCE_M:
		return "HandPoint is %.3f m from the body's HandPoint %s, expected within %.2f m" \
			% [hand_gap, body_hand.global_position, HAND_TOLERANCE_M]

	var body_mesh := expected.find_child(BODY_MESHES[kind], true, false) as MeshInstance3D
	if body_mesh == null:
		return "no %s mesh" % BODY_MESHES[kind]
	var to_player := player.global_transform.affine_inverse() * body_mesh.global_transform
	var head_top := (to_player * body_mesh.get_aabb()).end.y
	var anchor_y := player.overhead_anchor.position.y
	if absf(anchor_y - (head_top + OVERHEAD_CLEARANCE_M)) > OVERHEAD_TOLERANCE_M:
		return "OverheadAnchor at y=%.3f, expected %.3f (head %.3f + %.2f)" \
			% [anchor_y, head_top + OVERHEAD_CLEARANCE_M, head_top, OVERHEAD_CLEARANCE_M]
	if not is_equal_approx(anchor_y, bodies.get_overhead_height()):
		return "OverheadAnchor at y=%.3f, get_overhead_height() %.3f" % [anchor_y, bodies.get_overhead_height()]
	print("[player_test] %s: hand %.3f m off, anchor %.3f m over a %.3f m head" \
		% [BODY_NODES[kind], hand_gap, anchor_y, head_top])
	return ""


## Samples melee_slash, cast_staff and ranged_bow: the weapon's long axis (mesh
## local +Y, grip to tip) stays in the forward/up plane, pointing down for the
## blades and up for the staff.
func _check_weapon_axis(kind: int) -> String:
	var anim_player := player.attack_animation_player
	if anim_player == null:
		return "no AttackAnimations player"
	var points_up := kind == int(Soul.Kind.MAGE)
	var failure := _weapon_axis_problem("rest", points_up)
	if not failure.is_empty():
		return failure
	for anim_name in WEAPON_ANIMATIONS:
		var anim := anim_player.get_animation(anim_name)
		if anim == null:
			return "no %s animation" % anim_name
		anim_player.play(anim_name)
		for t in ANIMATION_SAMPLES:
			if t > anim.length:
				break
			anim_player.seek(t, true)
			failure = _weapon_axis_problem("%s at %.2f s" % [anim_name, t], points_up)
			if not failure.is_empty():
				break
		anim_player.stop()
		player.equipped_weapon_holder.position = Player3D.HOLDER_REST_POSITION
		player.equipped_weapon_holder.rotation = Vector3.ZERO
		player.model.scale = Vector3.ONE
		if not failure.is_empty():
			return failure
	return ""


func _weapon_axis_problem(label: String, points_up: bool) -> String:
	var weapon := player.equipped_weapon_mesh
	var axis := (player.global_transform.basis.inverse() * weapon.global_transform.basis.y).normalized()
	if absf(axis.x) > MAX_SIDEWAYS_AXIS:
		return "%s: the weapon lies sideways (axis %s in body space)" % [label, axis]
	if points_up and axis.y <= 0.0:
		return "%s: the staff points down (axis %s in body space)" % [label, axis]
	if not points_up and axis.y >= 0.0:
		return "%s: the blade points up (axis %s in body space)" % [label, axis]
	return ""


## 3. Turn mode: one shift per turn.
func _step_turn_shifting() -> String:
	await _pause(0.05)
	player.set_turn_based_combat(true)
	player.start_turn(6.0)
	if player.get_shifts_left() != Player3D.SHIFTS_PER_TURN:
		return "turn shifting: %d shifts at turn start, expected %d" % [player.get_shifts_left(), Player3D.SHIFTS_PER_TURN]
	if not _shift(Soul.Kind.ROGUE):
		return "turn shifting: the first shift of the turn was refused"
	if _shift(Soul.Kind.MAGE):
		return "turn shifting: a second shift in the same turn was allowed"
	if player.get_shifts_left() != 0:
		return "turn shifting: get_shifts_left() %d after the shift, expected 0" % player.get_shifts_left()
	if player.can_shift():
		return "turn shifting: can_shift() still true with no shift left"
	if player.get_active_soul().kind != Soul.Kind.ROGUE:
		return "turn shifting: the refused shift changed the soul to %s" % player.get_active_soul().title
	return ""


## 4. Melee: the hit lands after the contact delay and spends the attack; out of
## reach is refused without spending it.
func _step_melee() -> String:
	player.start_turn(6.0)
	if not _shift(Soul.Kind.KNIGHT):
		return "melee: could not shift to the knight"
	var target := _targets[0]
	_place(target, Vector3(1.0, 0.0, 0.0))
	await _pause(0.05)

	var before := _health_of(target)
	var expected_damage := player.get_melee_damage()
	var start_msec := Time.get_ticks_msec()
	_watch_health(target, before)
	var swung: bool = await player.try_attack(target)
	var after := _health_of(target)
	await _let_watcher_catch_up()
	if not swung:
		return "melee: try_attack returned false for a target at 1.0 m"
	if after != before - expected_damage:
		return "melee: target health %d -> %d, expected a drop of %d" % [before, after, expected_damage]
	if _hit_msec < 0:
		return "melee: the watcher never saw the hit land"
	var contact_ms := _hit_msec - start_msec
	var delay_ms := int(round(player.melee_hit_delay * 1000.0))
	if contact_ms < delay_ms - TIMING_TOLERANCE_MS:
		return "melee: damage landed %d ms after the swing, before the %d ms contact delay" % [contact_ms, delay_ms]
	if player.can_turn_attack():
		return "melee: can_turn_attack() still true after the swing"
	print("[player_test] melee contact after %d ms (delay %d ms)" % [contact_ms, delay_ms])

	player.start_turn(6.0)
	var far := _targets[1]
	_place(far, Vector3(FAR_MELEE_M, 0.0, 0.0))
	await _pause(0.05)
	var far_before := _health_of(far)
	var far_swung: bool = await player.try_attack(far)
	if far_swung:
		return "melee: try_attack returned true for a target at %.1f m" % FAR_MELEE_M
	if _health_of(far) != far_before:
		return "melee: the refused attack still damaged the far target"
	if not player.can_turn_attack():
		return "melee: the refused attack spent the turn's attack"
	return ""


## 5. The rogue's throw: damage lands when the bolt arrives; beyond 12 m refused.
func _step_throw() -> String:
	player.start_turn(6.0)
	if not _shift(Soul.Kind.ROGUE):
		return "throw: could not shift to the rogue"
	var target := _targets[0]
	_place(target, Vector3(5.0, 0.0, 0.0))
	await _pause(0.05)

	var distance := GroundMath.ground_distance(player.global_position, target.global_position)
	var expected_flight := clampf(distance / player.ranged_bolt_speed,
		Player3D.BOLT_FLIGHT_MIN_SECONDS, Player3D.BOLT_FLIGHT_MAX_SECONDS)
	var expected_ms := int(round(expected_flight * 1000.0))
	var before := _health_of(target)
	var start_msec := Time.get_ticks_msec()
	_watch_health(target, before)
	var thrown: bool = await player.try_ranged_attack(target)
	var after := _health_of(target)
	await _let_watcher_catch_up()
	if not thrown:
		return "throw: try_ranged_attack returned false for a target at %.1f m" % distance
	if after != before - Soul.ROGUE_RANGED_DAMAGE:
		return "throw: target health %d -> %d, expected a drop of %d" % [before, after, Soul.ROGUE_RANGED_DAMAGE]
	if _hit_msec < 0:
		return "throw: the watcher never saw the hit land"
	var flight_ms := _hit_msec - start_msec
	if flight_ms < expected_ms - TIMING_TOLERANCE_MS:
		return "throw: damage landed after %d ms, before the %d ms bolt flight (%.2f m at %.1f m/s)" \
			% [flight_ms, expected_ms, distance, player.ranged_bolt_speed]
	if flight_ms > expected_ms + BOLT_SLACK_MS:
		return "throw: damage landed after %d ms, far later than the %d ms bolt flight" % [flight_ms, expected_ms]
	if player.can_turn_attack():
		return "throw: can_turn_attack() still true after the throw"
	print("[player_test] bolt landed after %d ms (flight %d ms over %.2f m)" % [flight_ms, expected_ms, distance])

	player.start_turn(6.0)
	var far := _targets[1]
	_place(far, Vector3(FAR_THROW_M, 0.0, 0.0))
	await _pause(0.05)
	var far_before := _health_of(far)
	var far_thrown: bool = await player.try_ranged_attack(far)
	if far_thrown:
		return "throw: try_ranged_attack returned true for a target at %.1f m" % FAR_THROW_M
	if _health_of(far) != far_before:
		return "throw: the refused throw still damaged the far target"
	if not player.can_turn_attack():
		return "throw: the refused throw spent the turn's attack"
	return ""


## 6. The mage's spells: Arcane Burst hits everyone near the target, Frost
## Snare damages, roots and recharges over two turns.
func _step_spells() -> String:
	player.start_turn(6.0)
	if not _shift(Soul.Kind.MAGE):
		return "spells: could not shift to the mage"
	var t1 := _targets[0]
	var t2 := _targets[1]
	var t3 := _targets[2]
	_place(t1, Vector3(3.0, 0.0, 0.0))
	_place(t2, Vector3(3.0, 0.0, 1.5))
	_place(t3, Vector3(-8.0, 0.0, -8.0))
	await _pause(0.05)

	var b1 := _health_of(t1)
	var b2 := _health_of(t2)
	var b3 := _health_of(t3)
	var burst: bool = await player.try_cast_spell(Soul.SPELL_ARCANE_BURST, t1)
	if not burst:
		return "spells: try_cast_spell(arcane_burst) returned false"
	if _health_of(t1) != b1 - Soul.ARCANE_BURST_DAMAGE:
		return "spells: arcane burst target health %d -> %d, expected a drop of %d" \
			% [b1, _health_of(t1), Soul.ARCANE_BURST_DAMAGE]
	if _health_of(t2) != b2 - Soul.ARCANE_BURST_DAMAGE:
		return "spells: the enemy 1.5 m from the target went %d -> %d, expected a drop of %d" \
			% [b2, _health_of(t2), Soul.ARCANE_BURST_DAMAGE]
	if _health_of(t3) != b3:
		return "spells: the enemy far from the burst was hit (%d -> %d)" % [b3, _health_of(t3)]
	if player.can_turn_attack():
		return "spells: can_turn_attack() still true after the cast"

	player.start_turn(6.0)
	var snare_before := _health_of(t2)
	var snared: bool = await player.try_cast_spell(Soul.SPELL_FROST_SNARE, t2)
	if not snared:
		return "spells: try_cast_spell(frost_snare) returned false"
	if _health_of(t2) != snare_before - Soul.FROST_SNARE_DAMAGE:
		return "spells: frost snare target health %d -> %d, expected a drop of %d" \
			% [snare_before, _health_of(t2), Soul.FROST_SNARE_DAMAGE]
	if not bool(t2.call("is_rooted")):
		return "spells: the frost snare target is not rooted"
	var cooldown := player.get_spell_cooldown(Soul.SPELL_FROST_SNARE)
	if cooldown != Soul.FROST_SNARE_COOLDOWN_TURNS:
		return "spells: frost snare cooldown %d right after the cast, expected %d" % [cooldown, Soul.FROST_SNARE_COOLDOWN_TURNS]

	player.start_turn(6.0)
	var ticked := player.get_spell_cooldown(Soul.SPELL_FROST_SNARE)
	if ticked != Soul.FROST_SNARE_COOLDOWN_TURNS - 1:
		return "spells: frost snare cooldown %d one turn later, expected %d" % [ticked, Soul.FROST_SNARE_COOLDOWN_TURNS - 1]
	var recharge_before := _health_of(t2)
	var recast: bool = await player.try_cast_spell(Soul.SPELL_FROST_SNARE, t2)
	if recast:
		return "spells: frost snare could be cast again while recharging (%d turns left)" % ticked
	if _health_of(t2) != recharge_before:
		return "spells: the refused recast still damaged the target"
	if not player.can_turn_attack():
		return "spells: the refused recast spent the turn's attack"
	if player.get_spell_cooldown(Soul.SPELL_ARCANE_BURST) != 0:
		return "spells: arcane burst has a cooldown of %d, expected none" % player.get_spell_cooldown(Soul.SPELL_ARCANE_BURST)
	return ""


## 7. Reactions as the knight: no press, the block stance, and a perfect press
## that negates the hit and earns the Resonance shift.
func _step_reactions() -> String:
	player.start_turn(6.0)
	if not _shift(Soul.Kind.KNIGHT):
		return "reactions: could not shift to the knight"
	player.heal(player.max_health)
	await _pause(0.05)
	if player.health != player.max_health or player.health != 100:
		return "reactions: knight health %d, expected 100" % player.health
	var attacker := _targets[0]
	_place(attacker, Vector3(1.0, 0.0, 0.0))
	var soul := player.get_active_soul()

	# No press: the 2D take_damage maths for a 12 hit with KNIGHT_DEFENCE.
	var expected_plain := maxi(1, int(ceil(float(ENEMY_DAMAGE) * soul.defence_mult)))
	var hp := player.health
	player.begin_enemy_counter_windup(attacker, ENEMY_DAMAGE)
	player.begin_enemy_counter_strike()
	var perfect := player.resolve_enemy_attack(attacker, ENEMY_DAMAGE)
	if perfect:
		return "reactions: resolve_enemy_attack reported a perfect press with no press"
	if player.health != hp - expected_plain:
		return "reactions: health %d -> %d with no press, expected a drop of %d (12 x %.2f, ceil)" \
			% [hp, player.health, expected_plain, soul.defence_mult]
	await _pause(0.05)

	# Block stance: half of that, same rounding.
	player.set_blocking(true)
	if not player.is_blocking():
		return "reactions: set_blocking(true) did not take as the knight"
	var expected_blocked := maxi(1, int(ceil(float(expected_plain) * 0.5)))
	hp = player.health
	player.begin_enemy_counter_windup(attacker, ENEMY_DAMAGE)
	player.begin_enemy_counter_strike()
	perfect = player.resolve_enemy_attack(attacker, ENEMY_DAMAGE)
	if perfect:
		return "reactions: a blocked hit with no press counted as perfect"
	if player.health != hp - expected_blocked:
		return "reactions: health %d -> %d while blocking, expected a drop of %d (half of %d, ceil)" \
			% [hp, player.health, expected_blocked, expected_plain]
	player.set_blocking(false)
	if player.is_blocking():
		return "reactions: set_blocking(false) left the stance up"
	await _pause(0.05)

	# Perfect press during the strike: the knight negates the hit; Resonance
	# grants the extra shift on the next turn.
	hp = player.health
	player.begin_enemy_counter_windup(attacker, ENEMY_DAMAGE)
	player.begin_enemy_counter_strike()
	player._register_counter_press()
	perfect = player.resolve_enemy_attack(attacker, ENEMY_DAMAGE)
	if not perfect:
		return "reactions: a press during the strike was not reported as perfect"
	if player.health != hp:
		return "reactions: health %d -> %d on a perfect block, expected no change" % [hp, player.health]
	player.start_turn(6.0)
	var expected_shifts := Player3D.SHIFTS_PER_TURN + (1 if Player3D.PERFECT_REACTION_GRANTS_EXTRA_SHIFT else 0)
	if player.get_shifts_left() != expected_shifts:
		return "reactions: %d shifts after the Resonance turn started, expected %d" % [player.get_shifts_left(), expected_shifts]
	# Once per enemy turn: the next turn is back to the base count.
	player.start_turn(6.0)
	if player.get_shifts_left() != Player3D.SHIFTS_PER_TURN:
		return "reactions: Resonance carried into a second turn (%d shifts)" % player.get_shifts_left()
	return ""


## 8. XP: two 50 XP grants from level 1 follow the ported level formula.
func _step_xp() -> String:
	await _pause(0.05)
	var level0 := player.get_player_level()
	if level0 != 1:
		return "xp: the player starts at level %d, expected 1" % level0
	var need0 := player.get_xp_required_for_next_level()
	var expected_need0 := Player3D.XP_BASE_TO_LEVEL_2 * pow(Player3D.XP_PER_LEVEL_MULT, float(level0 - 1))
	if not is_equal_approx(need0, expected_need0):
		return "xp: %.1f XP needed at level 1, expected %.1f" % [need0, expected_need0]

	player.add_experience(50)
	player.add_experience(50)
	var expected_level := level0
	var expected_toward := 100.0
	while expected_toward + 0.0001 >= Player3D.XP_BASE_TO_LEVEL_2 * pow(Player3D.XP_PER_LEVEL_MULT, float(expected_level - 1)):
		expected_toward -= Player3D.XP_BASE_TO_LEVEL_2 * pow(Player3D.XP_PER_LEVEL_MULT, float(expected_level - 1))
		expected_level += 1
	if player.get_player_level() != expected_level:
		return "xp: level %d after 100 XP, expected %d" % [player.get_player_level(), expected_level]
	if not is_equal_approx(player.get_experience_toward_next(), expected_toward):
		return "xp: %.2f XP toward the next level, expected %.2f" % [player.get_experience_toward_next(), expected_toward]
	var expected_need := Player3D.XP_BASE_TO_LEVEL_2 * pow(Player3D.XP_PER_LEVEL_MULT, float(expected_level - 1))
	if not is_equal_approx(player.get_xp_required_for_next_level(), expected_need):
		return "xp: %.1f XP needed at level %d, expected %.1f" \
			% [player.get_xp_required_for_next_level(), expected_level, expected_need]
	return ""
