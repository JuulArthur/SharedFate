class_name Waystone3D
extends StaticBody3D

## Track A: a waystone (docs/gameplay-expansion.md section 3, "Interactables"
## and "Waystones").
##
## A standing stone with a glowing rune, on the prop layer (8), in group
## `interactable`. `interact(player)` sends the player to the stone whose
## `waystone_id` equals this stone's `destination_id`, landing 1.5 m in front
## of it (its local -Z), through `player.teleport_to(point)`, then tells the
## coordinator with `on_player_teleported`. Refused, with a popup, while a
## fight runs.
##
## Track A addition: a destination must be attuned first (the player has stood
## within `attune_radius` of it once, or it starts attuned), so a network
## never skips ahead of where the player has walked. The rune glows brighter
## once attuned.

const INTERACTABLE_GROUP := &"interactable"
const WAYSTONE_GROUP := &"waystones"
const PROP_LAYER := 8
const ARRIVAL_DISTANCE_M := 1.5
const STONE_SIZE := Vector3(0.9, 2.3, 0.55)
const COLOR_STONE := Color(0.45, 0.46, 0.5)
const COLOR_BASE := Color(0.3, 0.3, 0.32)
const COLOR_RUNE_DORMANT := Color(0.25, 0.55, 0.7, 1.0)
const COLOR_RUNE_ATTUNED := Color(0.55, 1.4, 1.8, 1.0)
const COLOR_TELEPORT := Color(0.55, 0.95, 1.0, 1.0)
const POPUP_OFFSET := Vector3(0.0, 2.7, 0.0)

## Emitted after this stone has sent `player` to `destination`.
signal teleported(player: Node3D, destination: Waystone3D)

@export var waystone_id: StringName = &""
@export var destination_id: StringName = &""
@export var display_name := "Waystone"
@export var start_attuned := false
@export var attune_radius := 4.0
@export var interact_range := 2.0

var attuned := false
var _hover_highlighted := false
var _model: Node3D = null
var _rune_material: StandardMaterial3D = null
var _light: OmniLight3D = null


func _ready() -> void:
	collision_layer = PROP_LAYER
	collision_mask = 0
	add_to_group(INTERACTABLE_GROUP)
	add_to_group(WAYSTONE_GROUP)
	var shape := BoxShape3D.new()
	shape.size = Vector3(STONE_SIZE.x + 0.2, STONE_SIZE.y, STONE_SIZE.z + 0.2)
	WorldFx3D.add_shape(self, shape, Vector3(0.0, STONE_SIZE.y * 0.5, 0.0))
	_build_model()
	_set_attuned(start_attuned, false)


func _physics_process(_delta: float) -> void:
	if attuned:
		return
	var player := WorldFx3D.find_player(get_tree())
	if player == null:
		return
	if GroundMath.ground_distance(player.global_position, global_position) <= attune_radius:
		_set_attuned(true, true)


# --- Interactable contract (gameplay expansion section 3) ---------------------

func interact(player: Node3D) -> void:
	if player == null or not is_instance_valid(player):
		return
	if WorldFx3D.is_combat_running(get_tree()):
		_popup("Not during a fight", CombatFx.COLOR_WARNING)
		return
	if not attuned:
		_set_attuned(true, true)
	var destination := get_destination()
	if destination == null:
		_popup("The stone is silent", CombatFx.COLOR_WARNING)
		return
	if not destination.attuned:
		_popup("%s is not attuned yet" % destination.display_name, CombatFx.COLOR_WARNING)
		return
	var point := destination.get_arrival_point()
	CombatFx.ring_burst(self, GroundMath.flatten(player.global_position, 0.05), COLOR_TELEPORT,
		6.0 * WorldFx3D.FX_SCREEN_SCALE, 30.0 * WorldFx3D.FX_SCREEN_SCALE, 0.4)
	if player.has_method("teleport_to"):
		player.call("teleport_to", point)
	else:
		_fallback_teleport(player, point)
	WorldFx3D.notify_coordinator(get_tree(), &"on_player_teleported")
	destination.play_arrival_fx(point)
	teleported.emit(player, destination)


func get_interact_range() -> float:
	return interact_range


func get_interact_label() -> String:
	var destination := get_destination()
	if destination == null:
		return "Waystone"
	if not destination.attuned:
		return "Waystone: %s (not attuned)" % destination.display_name
	return "Waystone: to %s" % destination.display_name


func can_interact() -> bool:
	return not WorldFx3D.is_combat_running(get_tree())


func set_hover_highlighted(enabled: bool) -> void:
	if _hover_highlighted == enabled:
		return
	_hover_highlighted = enabled
	WorldFx3D.set_highlight(_model, enabled)


func is_hover_highlighted() -> bool:
	return _hover_highlighted


# --- Network -------------------------------------------------------------------

## The stone this one sends the player to, or null.
func get_destination() -> Waystone3D:
	if destination_id == &"" or not is_inside_tree():
		return null
	for node in get_tree().get_nodes_in_group(WAYSTONE_GROUP):
		var stone := node as Waystone3D
		if stone != null and stone != self and stone.waystone_id == destination_id:
			return stone
	return null


## Where a traveller arriving at this stone lands: 1.5 m in front (local -Z),
## on the ground.
func get_arrival_point() -> Vector3:
	return GroundMath.flatten(global_transform * Vector3(0.0, 0.0, -ARRIVAL_DISTANCE_M))


## Attunes the stone (a quest reward, a test).
func attune() -> void:
	_set_attuned(true, true)


func play_arrival_fx(point: Vector3) -> void:
	CombatFx.ring_burst(self, point + Vector3(0.0, 0.05, 0.0), COLOR_TELEPORT,
		30.0 * WorldFx3D.FX_SCREEN_SCALE, 6.0 * WorldFx3D.FX_SCREEN_SCALE, 0.4)
	if _model != null:
		HitFlash3D.flash_node(_model, Color(0.6, 1.4, 1.8, 1.0), 0.3)


## Without the lead's `teleport_to` (gameplay expansion section 4): snap to the
## nearest navmesh point and drop the camera there.
func _fallback_teleport(player: Node3D, point: Vector3) -> void:
	var target := point
	var world := get_world_3d()
	if world != null and world.navigation_map.is_valid():
		var closest := NavigationServer3D.map_get_closest_point(world.navigation_map, point)
		if closest != Vector3.ZERO:
			target = GroundMath.flatten(closest)
	if player.has_method("stop_movement_immediately"):
		player.call("stop_movement_immediately")
	if player.has_method("snap_to"):
		player.call("snap_to", target)
	else:
		player.global_position = target
	var node: Node = self
	while node != null:
		var rig := node.get_node_or_null("CameraRig")
		if rig != null and rig.has_method("snap_to_target"):
			rig.call("snap_to_target")
			break
		node = node.get_parent()


func _set_attuned(value: bool, announce: bool) -> void:
	var changed := value != attuned
	attuned = value
	if _rune_material != null:
		_rune_material.albedo_color = COLOR_RUNE_ATTUNED if attuned else COLOR_RUNE_DORMANT
	if _light != null:
		_light.light_energy = 1.6 if attuned else 0.5
	if announce and changed and attuned:
		_popup("Waystone attuned", COLOR_TELEPORT)


func _popup(text: String, color: Color) -> void:
	CombatFx.popup_text(global_position + POPUP_OFFSET, text, color, 16)


func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	add_child(_model)
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 0.62
	base_mesh.bottom_radius = 0.72
	base_mesh.height = 0.22
	base_mesh.radial_segments = 7
	base_mesh.rings = 1
	WorldFx3D.add_mesh(_model, "Base", base_mesh, WorldFx3D.flat_material(COLOR_BASE), Vector3(0.0, 0.11, 0.0))
	var stone_mesh := BoxMesh.new()
	stone_mesh.size = STONE_SIZE
	WorldFx3D.add_mesh(_model, "Stone", stone_mesh, WorldFx3D.flat_material(COLOR_STONE),
		Vector3(0.0, STONE_SIZE.y * 0.5 + 0.1, 0.0), Vector3(2.0, 0.0, -2.5))
	var cap_mesh := PrismMesh.new()
	cap_mesh.size = Vector3(STONE_SIZE.x, 0.35, STONE_SIZE.z)
	WorldFx3D.add_mesh(_model, "Cap", cap_mesh, WorldFx3D.flat_material(COLOR_STONE * 0.9),
		Vector3(-0.05, STONE_SIZE.y + 0.26, 0.04), Vector3(2.0, 0.0, -2.5))
	# The rune on the front face (local -Z, the side travellers arrive on).
	_rune_material = WorldFx3D.glow_material(COLOR_RUNE_DORMANT)
	var rune_mesh := BoxMesh.new()
	rune_mesh.size = Vector3(0.12, 0.7, 0.03)
	WorldFx3D.add_mesh(_model, "RuneStem", rune_mesh, _rune_material,
		Vector3(0.0, 1.35, -STONE_SIZE.z * 0.5 - 0.02))
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(0.45, 0.1, 0.03)
	WorldFx3D.add_mesh(_model, "RuneBar", bar_mesh, _rune_material,
		Vector3(0.0, 1.5, -STONE_SIZE.z * 0.5 - 0.02), Vector3(0.0, 0.0, 20.0))
	WorldFx3D.add_mesh(_model, "RuneBar2", bar_mesh, _rune_material,
		Vector3(0.0, 1.2, -STONE_SIZE.z * 0.5 - 0.02), Vector3(0.0, 0.0, -20.0))
	_light = OmniLight3D.new()
	_light.name = "RuneLight"
	_light.light_color = COLOR_TELEPORT
	_light.omni_range = 4.0
	_light.position = Vector3(0.0, 1.4, -0.8)
	add_child(_light)
