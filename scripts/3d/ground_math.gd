class_name GroundMath
extends RefCounted

## Ground-plane math for the 3D port.
##
## Every turn, path and grid calculation stays in 2D on the XZ plane, exactly as
## the 2D game does it; conversion to and from Vector3 happens only at node
## boundaries and only through this class. See docs/3d-port-contracts.md, section 4.
##
## Conventions: 1 unit = 1 metre, +Y up, ground at y = 0, a character faces its
## local -Z. 2D Vector2(x, y) ground coordinates map to Vector3(x, 0, y).

const METER_WORLD_UNITS := 1.0
const CELL_SIZE := 1.0
const GROUND_Y := 0.0


static func to_ground(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


static func from_ground(g: Vector2, y: float = GROUND_Y) -> Vector3:
	return Vector3(g.x, y, g.y)


static func flatten(p: Vector3, y: float = GROUND_Y) -> Vector3:
	return Vector3(p.x, y, p.z)


static func ground_distance(a: Vector3, b: Vector3) -> float:
	return to_ground(a).distance_to(to_ground(b))


static func ground_direction(from: Vector3, to: Vector3) -> Vector3:
	var d := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if d.length_squared() <= 0.000001:
		return Vector3.ZERO
	return d.normalized()


static func path_length(points: Array[Vector3]) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += ground_distance(points[i - 1], points[i])
	return total


## Returns the prefix of `points` whose ground length is at most `max_length`.
## The last returned point is interpolated so the path ends exactly on budget.
static func trim_path(points: Array[Vector3], max_length: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if points.is_empty():
		return result
	result.append(points[0])
	if max_length <= 0.0:
		return result
	var remaining := max_length
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var segment := ground_distance(a, b)
		if segment <= remaining:
			result.append(b)
			remaining -= segment
			continue
		if segment > 0.0:
			result.append(a.lerp(b, remaining / segment))
		break
	return result


static func to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL_SIZE), floori(p.z / CELL_SIZE))


static func cell_center(c: Vector2i, y: float = GROUND_Y) -> Vector3:
	return Vector3((float(c.x) + 0.5) * CELL_SIZE, y, (float(c.y) + 0.5) * CELL_SIZE)


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## The rotation.y that makes a Node3D's local -Z axis point along `direction`
## (projected onto the ground plane). Returns 0.0 for a zero direction.
static func yaw_facing(direction: Vector3) -> float:
	if absf(direction.x) <= 0.000001 and absf(direction.z) <= 0.000001:
		return 0.0
	return atan2(-direction.x, -direction.z)


static func meters_to_units(meters: float) -> float:
	return meters * METER_WORLD_UNITS


static func units_to_meters(units: float) -> float:
	return units / METER_WORLD_UNITS
