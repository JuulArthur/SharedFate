class_name WorldPicker
extends RefCounted

## Screen-to-world picking for the 3D port.
## See docs/3d-port-contracts.md, sections 3 (layers) and 6.
##
## All static and stateless: every call takes the Camera3D to pick through,
## normally CameraRig3D.get_camera(). Rays are cast through the physics space of
## that camera's world, so the picker works in a SubViewport too.
##
## Layers, from section 3: 1 ground (bit value 1), 2 actors (2), 3 pickups (4),
## 4 props (8). Props are deliberately absent here: a click on a crate should
## fall through to the ground behind it, as it does in 2D.

const RAY_LENGTH := 500.0

const MASK_GROUND := 1
const MASK_ACTORS := 2
const MASK_PICKUPS := 4

## Ground-plane forgiveness when clicking an enemy: the metric twin of the 2D
## ENEMY_CLICK_RADIUS (24 px in scripts/main.gd). A click that misses the body
## but lands this close to an enemy's feet still selects that enemy.
const ENEMY_CLICK_RADIUS_METERS := 0.6


## The point where the click ray meets walkable ground (layer 1), or null.
static func pick_ground(camera: Camera3D, screen_pos: Vector2) -> Variant:
	var hit := _ray(camera, screen_pos, MASK_GROUND, false, true)
	if hit.is_empty():
		return null
	return hit.get("position")


## The enemy under the click: a CharacterBody3D on layer 2, in group "enemies"
## and alive. Prefers a direct hit on the body; failing that, the nearest alive
## enemy whose feet are within ENEMY_CLICK_RADIUS_METERS of the ground hit.
static func pick_enemy(camera: Camera3D, screen_pos: Vector2) -> Node3D:
	var hit := _ray(camera, screen_pos, MASK_ACTORS, false, true)
	if not hit.is_empty():
		var collider: Object = hit.get("collider")
		var body := collider as CharacterBody3D
		if _is_pickable_enemy(body):
			return body

	var ground: Variant = pick_ground(camera, screen_pos)
	if ground == null:
		return null
	var ground_point: Vector3 = ground
	var closest: Node3D = null
	var closest_distance := ENEMY_CLICK_RADIUS_METERS
	for node in camera.get_tree().get_nodes_in_group("enemies"):
		var enemy := node as CharacterBody3D
		if not _is_pickable_enemy(enemy):
			continue
		var distance := GroundMath.ground_distance(ground_point, enemy.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest = enemy
	return closest


## The dropped item under the click: an Area3D on layer 3. Returns the pickup
## node that owns the area (the nearest self-or-ancestor Node3D with an
## is_available method, i.e. ItemPickup3D), or the area itself, or null.
static func pick_pickup(camera: Camera3D, screen_pos: Vector2) -> Node3D:
	var hit := _ray(camera, screen_pos, MASK_PICKUPS, true, false)
	if hit.is_empty():
		return null
	var collider: Object = hit.get("collider")
	var area := collider as Area3D
	if area == null:
		return null
	var candidate: Node = area
	while candidate != null:
		if candidate.has_method("is_available") and candidate is Node3D:
			return candidate as Node3D
		candidate = candidate.get_parent()
	return area


## Where a world point lands on screen, for projected overlays (WP5).
static func world_to_screen(camera: Camera3D, world: Vector3) -> Vector2:
	if camera == null or not camera.is_inside_tree():
		return Vector2.ZERO
	return camera.unproject_position(world)


static func _ray(
	camera: Camera3D,
	screen_pos: Vector2,
	mask: int,
	collide_with_areas: bool,
	collide_with_bodies: bool
) -> Dictionary:
	if camera == null or not camera.is_inside_tree():
		return {}
	var world := camera.get_world_3d()
	if world == null:
		return {}
	var space := world.direct_space_state
	if space == null:
		return {}
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * RAY_LENGTH
	var params := PhysicsRayQueryParameters3D.create(from, to, mask)
	params.collide_with_areas = collide_with_areas
	params.collide_with_bodies = collide_with_bodies
	return space.intersect_ray(params)


static func _is_pickable_enemy(body: CharacterBody3D) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if not body.is_in_group("enemies"):
		return false
	if body.has_method("is_alive") and not bool(body.call("is_alive")):
		return false
	return true
