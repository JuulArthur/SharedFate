class_name WildsLayout
extends RefCounted

## Track A: the shape of the Wilds map (docs/wilds-map.md), shared by the
## builder (tools/build_wilds_3d.gd, which places the forest walls, trees and
## camps from it) and the runtime visuals (WildsGround3D paints the floor,
## WildsForest3D fills the deep forest with trees), so the map is described
## once.
##
## Coordinates are metres on the ground plane: `Vector2(x, z)` (GroundMath's
## 2D form, docs/3d-port-contracts.md section 4). North is -z, east is +x.
## Open ground is a union of round clearings and corridors (polylines with a
## half width); everything else is forest, which the builder turns into
## invisible prop-layer walls lined with trees.

## Half the side of the square map; the Ground box is twice this wide.
const MAP_HALF_M := 52.0
## Corridor half width: 2 m gives a 4 m path, 3 m of navmesh after the
## 0.5 m agent radius.
const CORRIDOR_HALF_WIDTH_M := 2.0
## Edge wobble so the clearings do not read as perfect circles.
const EDGE_WOBBLE_M := 0.6
const EDGE_WOBBLE_FREQUENCY := 0.11
const SEED := 4217

## Clearings: id, centre (x, z) and radius in metres.
const CLEARINGS: Array[Dictionary] = [
	{"id": &"start", "name": "Start Glade", "center": Vector2(-34.0, 34.0), "radius": 11.0},
	{"id": &"den", "name": "Wolf Den", "center": Vector2(-32.0, -10.0), "radius": 11.0},
	{"id": &"camp", "name": "Bandit Camp", "center": Vector2(6.0, 12.0), "radius": 12.0},
	{"id": &"ruins", "name": "Old Ruins", "center": Vector2(-2.0, -30.0), "radius": 12.0},
	{"id": &"approach", "name": "Warden's Gate", "center": Vector2(16.0, -31.0), "radius": 4.5},
	{"id": &"boss", "name": "Warden's Ring", "center": Vector2(36.0, -32.0), "radius": 11.0},
]

## Corridors as polylines of (x, z) points.
const CORRIDORS: Array = [
	[Vector2(-34.0, 34.0), Vector2(-37.0, 12.0), Vector2(-32.0, -10.0)],   # start - den
	[Vector2(-34.0, 34.0), Vector2(-14.0, 30.0), Vector2(6.0, 12.0)],      # start - camp
	[Vector2(6.0, 12.0), Vector2(3.0, -8.0), Vector2(-2.0, -30.0)],        # camp - ruins
	[Vector2(-32.0, -10.0), Vector2(-18.0, -26.0), Vector2(-2.0, -30.0)],  # den - ruins
	[Vector2(-2.0, -30.0), Vector2(16.0, -31.0), Vector2(36.0, -32.0)],    # ruins - gate - boss
]

static var _noise: FastNoiseLite = null


## Signed distance in metres from `point` (x, z) to the edge of the open
## ground: negative inside a clearing or corridor, positive in the forest.
static func distance_to_open(point: Vector2) -> float:
	var best := INF
	for clearing in CLEARINGS:
		var center: Vector2 = clearing["center"]
		var radius: float = clearing["radius"]
		best = minf(best, point.distance_to(center) - radius)
	for corridor in CORRIDORS:
		var points: Array = corridor
		for i in range(points.size() - 1):
			var a: Vector2 = points[i]
			var b: Vector2 = points[i + 1]
			var closest := Geometry2D.get_closest_point_to_segment(point, a, b)
			best = minf(best, point.distance_to(closest) - CORRIDOR_HALF_WIDTH_M)
	return best + _wobble(point)


## True where the ground is open (walkable in the design).
static func is_open(point: Vector2) -> bool:
	return distance_to_open(point) < 0.0


## Distance from `point` to the nearest corridor centre line, ignoring the
## clearings (the floor paints a trodden path along it).
static func distance_to_path_line(point: Vector2) -> float:
	var best := INF
	for corridor in CORRIDORS:
		var points: Array = corridor
		for i in range(points.size() - 1):
			var a: Vector2 = points[i]
			var b: Vector2 = points[i + 1]
			var closest := Geometry2D.get_closest_point_to_segment(point, a, b)
			best = minf(best, point.distance_to(closest))
	return best


## The clearing dictionary for `id`, or an empty one.
static func clearing(id: StringName) -> Dictionary:
	for entry in CLEARINGS:
		if entry["id"] == id:
			return entry
	return {}


## Centre of clearing `id` as a world point on the ground plane.
static func clearing_center(id: StringName) -> Vector3:
	var entry := clearing(id)
	if entry.is_empty():
		return Vector3.ZERO
	return GroundMath.from_ground(entry["center"])


static func _wobble(point: Vector2) -> float:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.seed = SEED
		_noise.frequency = EDGE_WOBBLE_FREQUENCY
	return _noise.get_noise_2d(point.x, point.y) * EDGE_WOBBLE_M
