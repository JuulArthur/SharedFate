class_name RangeRing3D
extends Node3D

## 3D twin of `RangeRing` (scripts/range_ring.gd): a flat ring on the ground that
## shows how far an attack reaches. Combat range checks are `distance_to` circles
## on the ground plane, so the ring is a true circle - what you see is exactly what
## the rules test.
##
## Parent it to the actor it belongs to (the player for the melee and throw rings,
## the hovered enemy for a blast radius); it follows that parent and sits just above
## the floor. Contract: docs/3d-port-contracts.md, section 7.
##
## The ring is a thin quad strip rather than a line so it keeps a real width at any
## zoom, and its material is unshaded with depth testing off so it reads over props
## and actors the same way the 2D ring read over the tilemap.

const SEGMENTS := 64
const DASH_COUNT := 24
## Fraction of each dash slot that is drawn; the rest is the gap. Same as 2D.
const DASH_FILL := 0.55
const DASH_SEGMENTS := 6
const RING_WIDTH_M := 0.06
const RING_Y := 0.02
## Radians per second the dashes turn, copied from RangeRing._process.
const SPIN_SPEED := 0.6

var radius := 1.0
var color := Color(1.0, 1.0, 1.0, 0.35)
var dashed := false

var _mesh: ImmediateMesh
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _spin := 0.0
var _shown := false


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = true
	_material.albedo_color = color

	_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "RingMesh"
	_mesh_instance.mesh = _mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.position = Vector3(0.0, RING_Y, 0.0)
	add_child(_mesh_instance)

	_rebuild()
	visible = _shown


func _process(delta: float) -> void:
	if not visible or not dashed or _mesh_instance == null:
		return
	# Slowly turning dashes so a large ring still reads as "active" while the
	# player picks a target.
	_spin += delta * SPIN_SPEED
	_mesh_instance.rotation.y = _spin


func show_ring(radius_m: float, new_color: Color, use_dashes := false) -> void:
	radius = radius_m
	color = new_color
	dashed = use_dashes
	_shown = true
	visible = true
	_rebuild()


func hide_ring() -> void:
	_shown = false
	visible = false


func _rebuild() -> void:
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	_material.albedo_color = color
	if radius <= 0.0:
		return
	if not dashed:
		_add_arc_strip(0.0, TAU, SEGMENTS)
		return
	var dash_span := TAU / float(DASH_COUNT)
	for i in range(DASH_COUNT):
		var start := float(i) * dash_span
		_add_arc_strip(start, start + dash_span * DASH_FILL, DASH_SEGMENTS)


## One quad strip between the inner and the outer radius, on the local XZ plane.
func _add_arc_strip(from_angle: float, to_angle: float, segments: int) -> void:
	var inner := maxf(0.0, radius - RING_WIDTH_M * 0.5)
	var outer := radius + RING_WIDTH_M * 0.5
	var steps := maxi(segments, 1)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _material)
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var angle := lerpf(from_angle, to_angle, t)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(direction * inner)
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(direction * outer)
	_mesh.surface_end()
