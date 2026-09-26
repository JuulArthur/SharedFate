class_name CameraRig3D
extends Node3D

## Fixed-angle orthographic camera rig for the 3D port.
## See docs/3d-port-contracts.md, sections 2 (camera row) and 6.
##
## The rig owns a Camera3D child named "Camera3D". The camera never rotates: it
## rides a fixed boom (yaw 45 degrees, pitch -35 degrees, 30 m back) and only its
## position is animated, by lerping a look-at point toward the follow target at
## CAMERA_FOLLOW_SPEED. That is the same lerp the 2D camera uses in
## scripts/main.gd, so the follow feels identical.
##
## Shake stays separate from the follow, exactly as in 2D where CombatFx writes
## Camera2D.offset while main.gd lerps the position: write `shake_offset` (screen
## plane, in metres) and the rig applies it through the camera's h_offset and
## v_offset, which never fight the follow.

## Metres per second of catch-up, mirroring main.gd's CAMERA_FOLLOW_SPEED.
const CAMERA_FOLLOW_SPEED := 6.0
## Default weight for focus_between, mirroring main.gd's CAMERA_ENEMY_FOCUS_BLEND.
const CAMERA_ENEMY_FOCUS_BLEND := 0.6
## Vertical extent of the orthographic frustum, in metres.
const DEFAULT_SIZE_METERS := 14.0
const CAMERA_YAW_DEGREES := 45.0
const CAMERA_PITCH_DEGREES := -35.0
## Distance from the look-at point to the camera. Far enough that near and far
## never clip a 6 m prop standing on the focus point.
const CAMERA_BOOM_METERS := 30.0
const CAMERA_NEAR := 0.05
const CAMERA_FAR := 200.0
## The look-at point rides at chest height, so the framing matches the 2D camera,
## which centred on the sprite rather than on the feet.
const LOOK_AT_HEIGHT := 1.0

## Screen-plane offset in metres, written per frame by the CombatFx shake adapter
## (docs/3d-port-contracts.md, section 7). Reset it to Vector2.ZERO when done.
var shake_offset := Vector2.ZERO

var _camera: Camera3D = null
var _follow_target: Node3D = null
var _focus_a: Node3D = null
var _focus_b: Node3D = null
var _focus_blend := CAMERA_ENEMY_FOCUS_BLEND
var _size_meters := DEFAULT_SIZE_METERS
## Camera orientation and boom offset, computed once: the rig is fixed-angle.
var _camera_basis := Basis.IDENTITY
var _boom := Vector3.ZERO
var _look_point := Vector3.ZERO
var _look_point_valid := false


func _ready() -> void:
	_camera_basis = Basis.from_euler(Vector3(
		deg_to_rad(CAMERA_PITCH_DEGREES), deg_to_rad(CAMERA_YAW_DEGREES), 0.0
	))
	# Basis.z is the camera's local backwards axis, so this lifts it up and back.
	_boom = _camera_basis.z * CAMERA_BOOM_METERS

	_camera = get_node_or_null("Camera3D") as Camera3D
	if _camera == null:
		# The scene should carry the child; build one so a bare Node3D still works.
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = _size_meters
	_camera.near = CAMERA_NEAR
	_camera.far = CAMERA_FAR
	_camera.global_transform = Transform3D(_camera_basis, _look_point + _boom)

	# Do not steal the view from a camera the level already made current.
	if get_viewport().get_camera_3d() == null:
		_camera.current = true


func _process(delta: float) -> void:
	if _camera == null:
		return
	_camera.h_offset = shake_offset.x
	_camera.v_offset = shake_offset.y

	var desired := Vector3.ZERO
	var focus_a := _live(_focus_a)
	var focus_b := _live(_focus_b)
	if focus_a != null and focus_b != null:
		desired = _look_at_point(focus_a).lerp(_look_at_point(focus_b), _focus_blend)
	else:
		var follow := _live(_follow_target)
		if follow == null:
			return
		desired = _look_at_point(follow)

	if _look_point_valid:
		_look_point = _look_point.lerp(desired, clampf(delta * CAMERA_FOLLOW_SPEED, 0.0, 1.0))
	else:
		_look_point = desired
		_look_point_valid = true
	_camera.global_transform = Transform3D(_camera_basis, _look_point + _boom)


# --- Contract (docs/3d-port-contracts.md, section 6) ---------------------------

## Smooth follow. Pass null to leave the camera where it is.
func set_follow_target(node: Node3D) -> void:
	_follow_target = node


## Enemy-turn framing: look at a point `blend` of the way from `a` to `b`
## (0.6 means 60 per cent toward `b`). Overrides the follow target until
## clear_focus(). Passing null for either node falls back to the follow target.
func focus_between(a: Node3D, b: Node3D, blend: float = CAMERA_ENEMY_FOCUS_BLEND) -> void:
	_focus_a = a
	_focus_b = b
	_focus_blend = clampf(blend, 0.0, 1.0)


func clear_focus() -> void:
	_focus_a = null
	_focus_b = null
	_focus_blend = CAMERA_ENEMY_FOCUS_BLEND


## Vertical extent of the orthographic frustum, in metres.
func set_zoom_size(size_m: float) -> void:
	_size_meters = maxf(0.1, size_m)
	if _camera != null:
		_camera.size = _size_meters


func get_camera() -> Camera3D:
	if _camera == null:
		_camera = get_node_or_null("Camera3D") as Camera3D
	return _camera


# --- Additions beyond the contract table ---------------------------------------

## Method form of `shake_offset`, so CombatFx.set_shake_target can take
## Callable(rig, "set_shake_offset") directly.
func set_shake_offset(offset: Vector2) -> void:
	shake_offset = offset


## Drops the camera on its target this instant instead of lerping to it. Use it
## after a teleport or a level load, where the 2D game called _center_camera().
func snap_to_target() -> void:
	_look_point_valid = false


# --- Internals -----------------------------------------------------------------

static func _live(node: Node3D) -> Node3D:
	if node != null and is_instance_valid(node):
		return node
	return null


static func _look_at_point(node: Node3D) -> Vector3:
	return GroundMath.flatten(node.global_position, LOOK_AT_HEIGHT)
