extends Node3D

## Approach 2 test: a pre-rendered background with a real-time character
## (docs/style-study/prerender_crypt.md).
##
## The crypt courtyard is rendered once in Blender
## (tools/blender/prerender/crypt_courtyard.py) from the game camera's angle.
## Here its proxy geometry is drawn with that painting projected from the
## camera (shaders/3d/prerender_projection.gdshader), so walls and pillars hide
## the mage per pixel while the camera follows him. The moonlight pass lets the
## mage's shadow darken only moonlit ground, the fire and sigil passes flicker
## and pulse, and a cast lights the painted surfaces through the diffuse colour
## pass.
##
## Controls: left click walks (navmesh baked at start from the proxies), C or
## right click casts, 1 to 8 jump to the test spots, the wheel zooms, V shows
## the proxy geometry. Headless, it checks the data, the navmesh and the
## occlusion rays and prints `PRERENDER OK`.

const DATA_DIR := "res://assets/3d/prerender/crypt/"
const SCENE_JSON := DATA_DIR + "crypt_scene.json"
const PROXY_GLB := DATA_DIR + "crypt_proxy.glb"
const MAGE_GLB := "res://assets/3d/models/styles/mage_soft.glb"
const CAMERA_RIG := "res://scenes/3d/camera_rig_3d.tscn"
const PROJECTION_SHADER := "res://shaders/3d/prerender_projection.gdshader"
const FLAME_SHADER := "res://shaders/3d/prerender_flame.gdshader"
const MAGE_SHADER := "res://shaders/3d/prerender_dark_mage.gdshader"
const GRADE_SHADER := "res://shaders/3d/prerender_grade.gdshader"

## Visual layers: the mage on 1, the proxies on 2, so the brazier lights (which
## the painting already holds) reach only the mage.
const LAYER_MAGE := 1
const LAYER_PROXY := 2
## Physics layers, as in the arena: floor 1, everything else 8 (props).
const PHYS_FLOOR := 1
const PHYS_OCCLUDER := 8

const WALK_SPEED := 1.9
## One walk cycle of mage_soft covers 0.886 m (docs/style-study/mage_soft.md).
const WALK_CYCLE_METERS := 0.886
const ZOOM_DEFAULT := 14.0
const ZOOM_MIN := 5.0
const ZOOM_MAX := 17.4
const SPOT_KEYS := ["spawn", "front_of_pillar", "behind_pillar", "behind_low_wall", "on_dais",
	"in_doorway", "behind_wall", "by_brazier"]
const CAST_PEAK := 0.68
const NAV_CELL := 0.1
const NAV_CELL_HEIGHT := 0.05

var data: Dictionary = {}
var _failures := PackedStringArray()
var _proxy_material: ShaderMaterial = null
var _proxy_root: Node3D = null
var _proxy_meshes: Array[MeshInstance3D] = []
var _nav_region: NavigationRegion3D = null
var _nav_ready := false
var _mage: Node3D = null
var _anim: AnimationPlayer = null
var _gem_materials: Array[ShaderMaterial] = []
var _staff_tip: Node3D = null
var _rig: CameraRig3D = null
var _follow: Node3D = null
var _moon: DirectionalLight3D = null
var _fire_lights: Array[OmniLight3D] = []
var _fire_energy: Array[float] = []
var _sigil_light: OmniLight3D = null
var _spell_light: OmniLight3D = null
var _path: PackedVector3Array = PackedVector3Array()
var _path_index := 0
var _zoom := ZOOM_DEFAULT
var _noise := FastNoiseLite.new()
var _time := 0.0
var _debug_geometry := false
var _hud: Label = null
var _cam_center := Vector3.ZERO
var _cam_right := Vector3.RIGHT
var _cam_up := Vector3.UP
var _view_size := Vector2.ONE
var _axis_u := Vector3.RIGHT
var _axis_v := Vector3.FORWARD


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = 60
	var text := FileAccess.get_file_as_string(SCENE_JSON)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		_fail("cannot read %s" % SCENE_JSON)
		_finish()
		return
	data = parsed
	_cam_center = _vec(data["cam_center"])
	_cam_right = _vec(data["cam_right"])
	_cam_up = _vec(data["cam_up"])
	_view_size = Vector2(data["view_size"][0], data["view_size"][1])
	_axis_u = _vec(data["uv_axes"]["u"])
	_axis_v = _vec(data["uv_axes"]["v"])
	_noise.seed = 7
	_noise.frequency = 1.0

	_build_environment()
	_build_proxies()
	_build_mage()
	_build_lights()
	_build_flames()
	_build_camera()
	_build_overlay()
	place_at("spawn")
	_bake_navigation.call_deferred()


# --- building -----------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.2, 0.23, 0.32)
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = env
	add_child(world)

	_moon = DirectionalLight3D.new()
	_moon.name = "Moon"
	var dir := _vec(data["moon"]["direction"]).normalized()
	_moon.basis = Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	var mc: Array = data["moon"]["color"]
	_moon.light_color = Color(mc[0], mc[1], mc[2])
	_moon.light_energy = 0.55
	_moon.shadow_enabled = true
	_moon.shadow_blur = 1.5
	_moon.directional_shadow_max_distance = 40.0
	_moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(_moon)


func _build_proxies() -> void:
	var textures: Dictionary = data["textures"]
	var shader := load(PROJECTION_SHADER) as Shader
	_proxy_material = ShaderMaterial.new()
	_proxy_material.shader = shader
	for key in ["color", "moon", "fire", "sigil", "albedo"]:
		var tex := load(DATA_DIR + String(textures[key])) as Texture2D
		if tex == null:
			_fail("missing texture %s" % textures[key])
			continue
		_proxy_material.set_shader_parameter(key + "_tex", tex)
	_proxy_material.set_shader_parameter("cam_center", _cam_center)
	_proxy_material.set_shader_parameter("cam_right", _cam_right)
	_proxy_material.set_shader_parameter("cam_up", _cam_up)
	_proxy_material.set_shader_parameter("view_size", _view_size)

	_nav_region = NavigationRegion3D.new()
	_nav_region.name = "NavigationRegion3D"
	add_child(_nav_region)
	var packed := load(PROXY_GLB) as PackedScene
	if packed == null:
		_fail("cannot load %s" % PROXY_GLB)
		return
	_proxy_root = packed.instantiate() as Node3D
	_proxy_root.name = "Proxy"
	_nav_region.add_child(_proxy_root)
	for node in _proxy_root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		mi.material_override = _proxy_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 1 << (LAYER_PROXY - 1)
		var body := StaticBody3D.new()
		body.name = mi.name + "_Col"
		body.collision_layer = PHYS_FLOOR if String(mi.name).begins_with("Walk_") else PHYS_OCCLUDER
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		shape.shape = mi.mesh.create_trimesh_shape()
		body.add_child(shape)
		mi.add_child(body)
		_proxy_meshes.append(mi)


func _build_mage() -> void:
	var packed := load(MAGE_GLB) as PackedScene
	if packed == null:
		_fail("cannot load %s" % MAGE_GLB)
		return
	_mage = Node3D.new()
	_mage.name = "Mage"
	add_child(_mage)
	var model := packed.instantiate() as Node3D
	_mage.add_child(model)
	var shader := load(MAGE_SHADER) as Shader
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		mi.layers = 1 << (LAYER_MAGE - 1)
		for s in range(mi.mesh.get_surface_count()):
			var original := mi.get_active_material(s) as BaseMaterial3D
			var mat := ShaderMaterial.new()
			mat.shader = shader
			if original != null:
				mat.set_shader_parameter("base_color", original.albedo_color)
				mat.set_shader_parameter("use_vertex_color", original.vertex_color_use_as_albedo)
				var gem := original.resource_name.contains("Gem") or original.emission_enabled
				mat.set_shader_parameter("is_gem", gem)
				if gem:
					_gem_materials.append(mat)
			mi.set_surface_override_material(s, mat)
	_anim = model.find_children("*", "AnimationPlayer", true, false).front() as AnimationPlayer
	if _anim != null:
		_anim.play(&"idle")
		_anim.animation_finished.connect(func(clip: StringName) -> void:
			if clip == &"cast":
				_anim.play(&"idle", 0.2))
	var staff := model.find_child("Staff", true, false) as Node3D
	_staff_tip = Node3D.new()
	_staff_tip.name = "StaffTip"
	if staff != null:
		staff.add_child(_staff_tip)
		_staff_tip.position = Vector3(0.0, 0.85, 0.0)
	else:
		_mage.add_child(_staff_tip)
		_staff_tip.position = Vector3(0.3, 2.0, -0.2)


func _build_lights() -> void:
	for entry in data["fire_lights"]:
		var light := OmniLight3D.new()
		var c: Array = entry["color"]
		light.light_color = Color(c[0], c[1], c[2])
		light.light_energy = 2.2
		light.omni_range = 6.5
		light.omni_attenuation = 1.3
		light.light_cull_mask = 1 << (LAYER_MAGE - 1)
		light.position = _vec(entry["position"])
		add_child(light)
		_fire_lights.append(light)
		_fire_energy.append(light.light_energy)
	var sig: Dictionary = data["sigil_light"]
	_sigil_light = OmniLight3D.new()
	var sc: Array = sig["color"]
	_sigil_light.light_color = Color(sc[0], sc[1], sc[2])
	_sigil_light.light_energy = 1.2
	_sigil_light.omni_range = 4.5
	_sigil_light.light_cull_mask = 1 << (LAYER_MAGE - 1)
	_sigil_light.position = _vec(sig["position"])
	add_child(_sigil_light)
	# The spell light reaches the painted surfaces too, through the albedo pass.
	_spell_light = OmniLight3D.new()
	_spell_light.name = "SpellLight"
	_spell_light.light_color = Color(1.0, 0.25, 0.12)
	_spell_light.light_energy = 0.0
	_spell_light.omni_range = 6.0
	_spell_light.omni_attenuation = 1.4
	_spell_light.light_cull_mask = (1 << (LAYER_MAGE - 1)) | (1 << (LAYER_PROXY - 1))
	_staff_tip.add_child(_spell_light)


func _build_flames() -> void:
	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 128
	noise_tex.height = 128
	noise_tex.seamless = true
	var fnl := FastNoiseLite.new()
	fnl.frequency = 0.04
	noise_tex.noise = fnl
	var shader := load(FLAME_SHADER) as Shader
	var index := 0
	for entry in data["flames"]:
		_add_flame(shader, noise_tex, _vec(entry["position"]), float(entry["width"]), float(entry["height"]), 1.5, index)
		index += 1
	for pos in data["candles"]:
		_add_flame(shader, noise_tex, _vec(pos) - Vector3(0.0, 0.03, 0.0), 0.07, 0.13, 1.1, index)
		index += 1


func _add_flame(shader: Shader, noise_tex: Texture2D, pos: Vector3, width: float, height: float,
		intensity: float, index: int) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)
	quad.center_offset = Vector3(0.0, height * 0.5, 0.0)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("noise_tex", noise_tex)
	mat.set_shader_parameter("intensity", intensity)
	mat.set_shader_parameter("seed", float(index) * 0.137)
	var mi := MeshInstance3D.new()
	mi.name = "Flame_%d" % index
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	add_child(mi)


func _build_camera() -> void:
	_follow = Node3D.new()
	_follow.name = "CameraFollow"
	add_child(_follow)
	var packed := load(CAMERA_RIG) as PackedScene
	_rig = packed.instantiate() as CameraRig3D
	_rig.name = "CameraRig"
	add_child(_rig)
	_rig.set_zoom_size(_zoom)
	_rig.set_follow_target(_follow)


func _build_overlay() -> void:
	var grade_layer := CanvasLayer.new()
	grade_layer.layer = 1
	add_child(grade_layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(GRADE_SHADER) as Shader
	rect.material = mat
	grade_layer.add_child(rect)
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 2
	add_child(hud_layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_color_override("font_color", Color(0.85, 0.8, 0.72, 0.85))
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.text = "Click: walk    C / right click: cast    1-8: test spots    Wheel: zoom    V: show proxy geometry"
	hud_layer.add_child(_hud)


func _bake_navigation() -> void:
	# Finer voxels than the arena: the doorway, the dais steps and the gaps
	# between rubble need them. The map must use the same cell size.
	var map := get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, NAV_CELL)
	NavigationServer3D.map_set_cell_height(map, NAV_CELL_HEIGHT)
	var nav := NavigationMesh.new()
	nav.cell_size = NAV_CELL
	nav.cell_height = NAV_CELL_HEIGHT
	nav.agent_radius = 0.4
	nav.agent_height = 1.9
	nav.agent_max_climb = 0.3
	nav.agent_max_slope = 35.0
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.geometry_collision_mask = PHYS_FLOOR | PHYS_OCCLUDER
	_nav_region.navigation_mesh = nav
	_nav_region.bake_navigation_mesh(false)
	# The map answers with (0, 0, 0) until it has synced the new mesh
	# (docs/3d-port-contracts.md, 5.1), so wait for a real closest point.
	var spawn := _vec(data["spots"]["spawn"])
	for i in range(240):
		await get_tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(map) == 0:
			continue
		var closest := NavigationServer3D.map_get_closest_point(map, spawn)
		if closest != Vector3.ZERO and GroundMath.ground_distance(closest, spawn) < 1.0:
			break
	_nav_ready = true
	print("PRERENDER navmesh polygons=%d" % nav.get_polygon_count())
	if DisplayServer.get_name() == "headless":
		_run_check()


# --- public, for the capture script -------------------------------------------

## Teleports the mage to a named spot from crypt_scene.json and drops the camera on it.
func place_at(spot: String, facing := Vector3.ZERO) -> void:
	if _mage == null or not data["spots"].has(spot):
		return
	_path = PackedVector3Array()
	_mage.global_position = _vec(data["spots"][spot])
	# Default: face the camera.
	var face := GroundMath.flatten(facing if facing != Vector3.ZERO else _vec(data["cam_back"]))
	if face.length() > 0.01:
		_mage.rotation.y = GroundMath.yaw_facing(face.normalized())
	if _anim != null:
		_anim.play(&"idle")
	_update_follow()
	if _rig != null:
		_rig.snap_to_target()


func set_zoom(size_m: float) -> void:
	_zoom = clampf(size_m, ZOOM_MIN, ZOOM_MAX)
	if _rig != null:
		_rig.set_zoom_size(_zoom)
	_update_follow()


func cast(hold_at := -1.0) -> void:
	if _anim == null or not _anim.has_animation(&"cast"):
		return
	_path = PackedVector3Array()
	_anim.play(&"cast")
	if hold_at >= 0.0:
		_anim.seek(hold_at, true)
		_anim.pause()


func set_debug_geometry(enabled: bool) -> void:
	_debug_geometry = enabled
	if _proxy_material != null:
		_proxy_material.set_shader_parameter("debug_geometry", 1.0 if enabled else 0.0)


func set_hud_visible(visible_hud: bool) -> void:
	if _hud != null:
		_hud.visible = visible_hud


# --- input and motion ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_walk_to_screen(mb.position)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			cast()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			set_zoom(_zoom * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			set_zoom(_zoom / 0.9)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_C:
			cast()
		elif key == KEY_V:
			set_debug_geometry(not _debug_geometry)
		elif key >= KEY_1 and key <= KEY_8:
			place_at(SPOT_KEYS[key - KEY_1])


func _walk_to_screen(screen_pos: Vector2) -> void:
	if not _nav_ready or _rig == null:
		return
	var cam := _rig.get_camera()
	var from := cam.project_ray_origin(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 300.0, PHYS_FLOOR)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var target: Vector3 = hit["position"]
	var rect: Array = data["walk_rect_uv"]
	var u := target.dot(_axis_u)
	var v := target.dot(_axis_v)
	if u < rect[0] or u > rect[1] or v < rect[2] or v > rect[3]:
		return
	_path = NavigationServer3D.map_get_path(get_world_3d().navigation_map, _mage.global_position, target, true)
	_path_index = 1 if _path.size() > 1 else 0
	if _anim != null and _anim.assigned_animation == "cast":
		_anim.play(&"idle")


func _physics_process(delta: float) -> void:
	if _mage == null:
		return
	if _path.is_empty() or _path_index >= _path.size():
		if _anim != null and _anim.current_animation == "walk":
			_anim.play(&"idle", 0.15)
		return
	var pos := _mage.global_position
	var goal := _path[_path_index]
	var to_goal := GroundMath.flatten(goal) - GroundMath.flatten(pos)
	var step := WALK_SPEED * delta
	if to_goal.length() <= step:
		pos = Vector3(goal.x, pos.y, goal.z)
		_path_index += 1
	else:
		var dir := to_goal.normalized()
		pos += dir * step
		_mage.rotation.y = GroundMath.yaw_facing(dir)
	pos.y = _floor_height(pos, pos.y)
	_mage.global_position = pos
	if _anim != null and _anim.current_animation != "walk":
		_anim.play(&"walk", 0.15)
	if _anim != null:
		_anim.speed_scale = WALK_SPEED / WALK_CYCLE_METERS


func _floor_height(pos: Vector3, fallback: float) -> float:
	var query := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 1.0, pos + Vector3.DOWN * 1.0, PHYS_FLOOR)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return (hit["position"] as Vector3).y if not hit.is_empty() else fallback


func _process(delta: float) -> void:
	_time += delta
	if _anim != null and _anim.current_animation != "walk":
		_anim.speed_scale = 1.0
	var fire := 1.0 + 0.2 * _noise.get_noise_1d(_time * 5.0) + 0.06 * sin(_time * 17.0)
	var sigil := 0.8 + 0.3 * sin(_time * 1.3) + 0.06 * _noise.get_noise_1d(_time * 3.0 + 40.0)
	if _proxy_material != null:
		_proxy_material.set_shader_parameter("fire_level", fire)
		_proxy_material.set_shader_parameter("sigil_level", sigil)
	for i in range(_fire_lights.size()):
		_fire_lights[i].light_energy = _fire_energy[i] * fire
	if _sigil_light != null:
		_sigil_light.light_energy = 1.2 * sigil
	var spell := 0.0
	if _anim != null and _anim.assigned_animation == "cast":
		var t := _anim.current_animation_position
		spell = exp(-pow((t - CAST_PEAK) / 0.12, 2.0))
	if _spell_light != null:
		_spell_light.light_energy = 7.0 * spell
	for mat in _gem_materials:
		mat.set_shader_parameter("gem_energy", 2.0 + 2.0 * sigil + 10.0 * spell)
	_update_follow()


## The camera follows the mage but never shows past the edge of the painting.
func _update_follow() -> void:
	if _mage == null or _follow == null or _rig == null:
		return
	var p := GroundMath.flatten(_mage.global_position, CameraRig3D.LOOK_AT_HEIGHT)
	var d := p - _cam_center
	var sx := d.dot(_cam_right)
	var sy := d.dot(_cam_up)
	var half_h := _zoom * 0.5
	var vp := get_viewport().get_visible_rect().size
	var half_w := half_h * (vp.x / maxf(vp.y, 1.0))
	var limit_x := maxf(0.0, _view_size.x * 0.5 - half_w)
	var limit_y := maxf(0.0, _view_size.y * 0.5 - half_h)
	var cx := clampf(sx, -limit_x, limit_x)
	var cy := clampf(sy, -limit_y, limit_y)
	# Moving along the ground's away axis shifts the screen by sin(35 deg) per metre.
	var away_per_screen := 1.0 / maxf(_axis_v.dot(_cam_up), 0.01)
	_follow.global_position = p + _cam_right * (cx - sx) + _axis_v * ((cy - sy) * away_per_screen)


# --- headless check -----------------------------------------------------------

func _run_check() -> void:
	var size: Array = data["image_size"]
	var color_tex := _proxy_material.get_shader_parameter("color_tex") as Texture2D
	if color_tex == null or color_tex.get_width() != int(size[0]) or color_tex.get_height() != int(size[1]):
		_fail("colour texture size %s, json says %s" % [
			Vector2i(color_tex.get_width(), color_tex.get_height()) if color_tex else "none", size])
	for key in ["moon", "fire", "sigil", "albedo"]:
		var tex := _proxy_material.get_shader_parameter(key + "_tex") as Texture2D
		if tex == null:
			_fail("no %s pass" % key)
		elif absi(tex.get_width() - int(size[0]) / 2) > 1:
			_fail("%s pass is %d px wide, expected %d" % [key, tex.get_width(), int(size[0]) / 2])
	print("PRERENDER proxies=%d textures colour=%dx%d" % [_proxy_meshes.size(),
		color_tex.get_width() if color_tex else 0, color_tex.get_height() if color_tex else 0])
	if _proxy_meshes.size() < 20:
		_fail("only %d proxy meshes" % _proxy_meshes.size())
	var cam := _rig.get_camera()
	var cb := cam.global_transform.basis
	if cb.x.dot(_cam_right) < 0.9999 or cb.y.dot(_cam_up) < 0.9999:
		_fail("render camera axes do not match CameraRig3D (x.dot=%.5f y.dot=%.5f)" % [cb.x.dot(_cam_right), cb.y.dot(_cam_up)])
	var map := get_world_3d().navigation_map
	var spots: Dictionary = data["spots"]
	var start := _vec(spots["spawn"])
	for goal_name in ["in_doorway", "behind_wall", "behind_low_wall", "on_dais"]:
		var goal := _vec(spots[goal_name])
		var path := NavigationServer3D.map_get_path(map, start, goal, true)
		var end := path[path.size() - 1] if not path.is_empty() else Vector3.INF
		var miss := GroundMath.ground_distance(end, goal) if not path.is_empty() else INF
		var length := 0.0
		for i in range(1, path.size()):
			length += GroundMath.ground_distance(path[i - 1], path[i])
		print("PRERENDER path spawn->%s points=%d length=%.1f m end miss=%.2f m" % [goal_name, path.size(), length, miss])
		if miss > 0.6:
			_fail("no path to %s (miss %.2f m)" % [goal_name, miss])
	var back := _vec(data["cam_back"]).normalized()
	var space := get_world_3d().direct_space_state
	for check in [["behind_pillar", 1.0, true], ["behind_low_wall", 0.45, true], ["behind_wall", 1.0, true],
			["in_doorway", 1.0, false], ["front_of_pillar", 1.0, false], ["spawn", 1.0, false]]:
		var origin := _vec(spots[check[0]]) + Vector3.UP * float(check[1])
		var query := PhysicsRayQueryParameters3D.create(origin, origin + back * 100.0, PHYS_OCCLUDER)
		var hit := space.intersect_ray(query)
		var hidden := not hit.is_empty()
		print("PRERENDER view ray from %s at %.2f m: %s%s" % [check[0], check[1], "hidden" if hidden else "visible",
			" by %s" % (hit["collider"] as Node).get_parent().name if hidden else ""])
		if hidden != bool(check[2]):
			_fail("%s should be %s" % [check[0], "hidden" if check[2] else "visible"])
	var floor_y := _floor_height(start, -99.0)
	if absf(floor_y) > 0.05:
		_fail("floor at spawn is %.3f m" % floor_y)
	if _anim == null or not _anim.has_animation(&"walk") or not _anim.has_animation(&"cast"):
		_fail("mage clips missing")
	_finish()


# --- helpers -------------------------------------------------------------------

static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _fail(message: String) -> void:
	_failures.append(message)
	push_error("PRERENDER: " + message)


func _finish() -> void:
	if _failures.is_empty():
		print("PRERENDER OK")
	else:
		print("PRERENDER FAILED: %s" % "; ".join(_failures))
	if DisplayServer.get_name() == "headless":
		get_tree().quit(0 if _failures.is_empty() else 1)
