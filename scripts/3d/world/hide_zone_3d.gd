class_name HideZone3D
extends Area3D

## Track A: cover (docs/gameplay-expansion.md section 3, "Cover").
##
## An Area3D on no layer that watches the actor layer (2). While the player's
## body is inside it calls `player.set_in_cover(self, true)`, and
## `set_in_cover(self, false)` when it leaves (both guarded by `has_method`;
## the lead implements them on the player). The bushes and tall grass are
## drawn procedurally at load from `size` and `visual_seed`, with no collider on the
## ground or prop layers, so cover never blocks movement or line of sight.

enum Style { BUSHES, TALL_GRASS }

const ACTOR_LAYER := 2
const PLAYER_GROUP := &"player"
const COLOR_BUSH_A := Color(0.18, 0.32, 0.16)
const COLOR_BUSH_B := Color(0.24, 0.4, 0.19)
const COLOR_GRASS_A := Color(0.42, 0.5, 0.24)
const COLOR_GRASS_B := Color(0.32, 0.44, 0.2)

## Footprint in metres (x, z) and the height of the trigger volume (y).
@export var size := Vector3(4.0, 1.4, 3.0)
@export var style: Style = Style.BUSHES
@export var visual_seed := 1

var _players_inside: Array[Node3D] = []


func _ready() -> void:
	collision_layer = 0
	collision_mask = ACTOR_LAYER
	monitoring = true
	monitorable = false
	var shape := BoxShape3D.new()
	shape.size = size
	WorldFx3D.add_shape(self, shape, Vector3(0.0, size.y * 0.5, 0.0))
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_build_visual()


func _exit_tree() -> void:
	# Leaving the tree with the player inside must not strand it in cover.
	for player in _players_inside:
		if is_instance_valid(player) and player.has_method("set_in_cover"):
			player.call("set_in_cover", self, false)
	_players_inside.clear()


## True while the player's body stands in this zone.
func has_player_inside() -> bool:
	return not _players_inside.is_empty()


func _on_body_entered(body: Node3D) -> void:
	if body == null or not body.is_in_group(PLAYER_GROUP):
		return
	if not _players_inside.has(body):
		_players_inside.append(body)
	if body.has_method("set_in_cover"):
		body.call("set_in_cover", self, true)


func _on_body_exited(body: Node3D) -> void:
	if body == null or not body.is_in_group(PLAYER_GROUP):
		return
	_players_inside.erase(body)
	if body.has_method("set_in_cover"):
		body.call("set_in_cover", self, false)


func _build_visual() -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	add_child(visual)
	var rng := RandomNumberGenerator.new()
	rng.seed = visual_seed
	var area := size.x * size.z
	if style == Style.BUSHES:
		_build_bushes(visual, rng, area)
	else:
		_build_grass(visual, rng, area)


## Low-poly blobs: squashed spheres with few segments, two greens.
func _build_bushes(visual: Node3D, rng: RandomNumberGenerator, area: float) -> void:
	var materials: Array[StandardMaterial3D] = [
		WorldFx3D.flat_material(COLOR_BUSH_A, 0.95),
		WorldFx3D.flat_material(COLOR_BUSH_B, 0.95),
	]
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 7
	sphere.rings = 4
	var count := clampi(int(area / 1.1), 3, 24)
	for i in range(count):
		var local := Vector3(rng.randf_range(-0.5, 0.5) * size.x * 0.85, 0.0,
			rng.randf_range(-0.5, 0.5) * size.z * 0.85)
		var radius := rng.randf_range(0.45, 0.8)
		var blob := WorldFx3D.add_mesh(visual, "Bush%d" % i, sphere, materials[i % 2],
			local + Vector3(0.0, radius * 0.55, 0.0), Vector3(0.0, rng.randf_range(0.0, 360.0), 0.0))
		blob.scale = Vector3(radius * 2.0, radius * rng.randf_range(1.2, 1.6), radius * 2.0)


## Tall grass: clusters of thin tilted blades.
func _build_grass(visual: Node3D, rng: RandomNumberGenerator, area: float) -> void:
	var materials: Array[StandardMaterial3D] = [
		WorldFx3D.flat_material(COLOR_GRASS_A, 1.0),
		WorldFx3D.flat_material(COLOR_GRASS_B, 1.0),
	]
	for material in materials:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var blade := PrismMesh.new()
	blade.size = Vector3(0.14, 1.0, 0.03)
	var count := clampi(int(area * 3.0), 12, 90)
	for i in range(count):
		var local := Vector3(rng.randf_range(-0.5, 0.5) * size.x, 0.0,
			rng.randf_range(-0.5, 0.5) * size.z)
		var height := rng.randf_range(0.8, 1.35)
		var tuft := WorldFx3D.add_mesh(visual, "Blade%d" % i, blade, materials[i % 2],
			local + Vector3(0.0, height * 0.5, 0.0),
			Vector3(rng.randf_range(-12.0, 12.0), rng.randf_range(0.0, 360.0), rng.randf_range(-12.0, 12.0)))
		tuft.scale = Vector3(1.0, height, 1.0)
		tuft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
