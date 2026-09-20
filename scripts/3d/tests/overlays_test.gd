extends Node3D

## WP5 test scene: every 3D overlay and the CombatFx 3D adapters, running over the
## WP0 arena layout and the WP0 stub actors.
##
## Run it headless for 120 frames; it prints `OVERLAYS OK` at frame 100 when every
## overlay reports visible and the adapters fired, otherwise the failing checks:
##   godot --headless --path . res://scenes/3d/tests/overlays_test.tscn --quit-after 120
##
## The frame numbers below, not wall-clock seconds, drive the counter prompt
## through all four phases, because a headless frame is far shorter than a real
## one. Contract: docs/3d-port-contracts.md, sections 7, 11 and 12.

const CAMERA_SIZE_M := 14.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

const FRAME_WINDUP := 10
const FRAME_POPUP := 20
const FRAME_HIT_FLASH := 30
const FRAME_RING_BURST := 40
const FRAME_STRIKE := 45
const FRAME_SHAKE := 50
const FRAME_RESULT := 60
const FRAME_HIDE := 75
const FRAME_WINDUP_AGAIN := 90
const FRAME_REPORT := 100

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var player: CharacterBody3D = $Player
@onready var enemy: CharacterBody3D = $Enemy
@onready var range_ring: RangeRing3D = $Player/RangeRing3D
@onready var player_bars: OverheadBars3D = $Player/OverheadAnchor/OverheadBars3D
@onready var enemy_bars: OverheadBars3D = $Enemy/OverheadAnchor/OverheadBars3D
@onready var counter_prompt: CounterPrompt3D = $Enemy/OverheadAnchor/CounterPrompt3D
@onready var enemy_flash: HitFlash3D = $Enemy/HitFlash3D
@onready var path_preview: PathPreview3D = $PathPreview3D

var _frame := 0
var _flash_applied := false
var _shake_offsets := 0
var _reported := false


func _ready() -> void:
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)

	# Section 7: every CombatFx world position is projected through this camera.
	CombatFx.set_world_projector(func(p: Variant) -> Vector2: return camera.unproject_position(p as Vector3))
	CombatFx.set_shake_target(_on_shake_offset)

	range_ring.show_ring(1.2, Color(1.0, 1.0, 1.0, 0.35))

	player_bars.set_ratio(1.0)
	enemy_bars.set_ratio(1.0)

	counter_prompt.set_hint("Block", Color(0.62, 0.82, 1.0))

	var points: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 3.0),
	]
	path_preview.show_path(points, 4.0, 2.0)


func _exit_tree() -> void:
	# The autoload outlives the scene; leave it in its 2D state.
	CombatFx.set_world_projector(Callable())
	CombatFx.set_shake_target(null)


func _process(_delta: float) -> void:
	_frame += 1
	match _frame:
		FRAME_WINDUP:
			counter_prompt.start_windup(0.55)
		FRAME_POPUP:
			CombatFx.popup_damage(enemy.global_position + Vector3(0.0, 1.4, 0.0), 12)
		FRAME_HIT_FLASH:
			enemy_flash.flash()
			_flash_applied = _enemy_mesh_has_overlay()
			enemy_bars.set_ratio(0.55)
		FRAME_RING_BURST:
			CombatFx.ring_burst(self, enemy.global_position + Vector3(0.0, 0.05, 0.0),
				CombatFx.COLOR_COUNTER)
		FRAME_STRIKE:
			counter_prompt.start_strike(0.18)
		FRAME_SHAKE:
			CombatFx.shake(6.0, 0.2)
		FRAME_RESULT:
			counter_prompt.show_result(true)
		FRAME_HIDE:
			counter_prompt.hide_prompt()
		FRAME_WINDUP_AGAIN:
			counter_prompt.start_windup(0.55)
		FRAME_REPORT:
			_report()


## The shake adapter from section 7: in a real level this is the camera rig's
## `shake_offset`. Here it only has to prove the callable is driven.
func _on_shake_offset(offset: Vector2) -> void:
	if offset != Vector2.ZERO:
		_shake_offsets += 1


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


func _enemy_mesh_has_overlay() -> bool:
	var mesh := enemy.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return false
	return mesh.material_overlay != null


func _report() -> void:
	if _reported:
		return
	_reported = true
	var failures: Array[String] = []
	_check(failures, "RangeRing3D visible", range_ring.visible)
	_check(failures, "CounterPrompt3D visible", counter_prompt.visible)
	_check(failures, "PathPreview3D visible", path_preview.visible)
	_check(failures, "OverheadBars3D (player) visible", player_bars.visible)
	_check(failures, "OverheadBars3D (enemy) visible", enemy_bars.visible)
	_check(failures, "HitFlash3D tinted the enemy meshes", _flash_applied)
	_check(failures, "CombatFx shake target driven", _shake_offsets > 0)
	if failures.is_empty():
		print("OVERLAYS OK")
		return
	for failure in failures:
		print("OVERLAYS FAILED: %s" % failure)


func _check(failures: Array[String], label: String, passed: bool) -> void:
	if not passed:
		failures.append(label)
