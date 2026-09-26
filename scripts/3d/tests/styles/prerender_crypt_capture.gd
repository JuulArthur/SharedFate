extends SceneTree

## Windowed screenshots of the pre-render test (docs/style-study/prerender_crypt.md):
##
##     godot --path . --script res://scripts/3d/tests/styles/prerender_crypt_capture.gd -- <out_dir>
##
## Loads scenes/3d/tests/styles/prerender_crypt_view.tscn and, for each shot,
## puts the mage on a named spot, sets the zoom, waits for the camera and the
## flames to settle, and saves the root viewport as
## <out_dir>/prerender_crypt_<shot>.png (scaled to 1600x900 when the window is
## larger). Needs a window: the headless renderer has no viewport texture.

const VIEW_SCENE := "res://scenes/3d/tests/styles/prerender_crypt_view.tscn"
const OUTPUT_SIZE := Vector2i(1600, 900)
const SETTLE_FRAMES := 40
const FIRST_SHOT_FRAME := 90

## name, spot, zoom (m), cast hold time (-1 = idle), debug geometry, facing (Godot direction, zero = camera)
const SHOTS := [
	["overview", "on_dais", 17.4, 0.68, false, Vector3(-1, 0, -1)],
	["behind_pillar", "behind_pillar", 7.0, -1.0, false, Vector3(1, 0, -1)],
	["behind_low_wall", "behind_low_wall", 7.0, -1.0, false, Vector3.ZERO],
	["in_doorway", "in_doorway", 8.0, -1.0, false, Vector3.ZERO],
	["by_brazier", "by_brazier", 5.5, -1.0, false, Vector3.ZERO],
	["cast", "front_of_pillar", 8.0, 0.68, false, Vector3(1, 0, 0)],
	["proxies", "on_dais", 17.4, -1.0, true, Vector3.ZERO],
]

var _frames := 0
var _out_dir := ""
var _view: Node = null
var _shot := -1
var _shot_frame := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out_dir = args[0] if args.size() > 0 else "user://"
	var packed := load(VIEW_SCENE) as PackedScene
	if packed == null:
		push_error("PRERENDER_CAPTURE: cannot load %s" % VIEW_SCENE)
		quit(1)
		return
	_view = packed.instantiate()
	root.add_child(_view)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < FIRST_SHOT_FRAME:
		return false
	if _shot < 0 or _frames - _shot_frame >= SETTLE_FRAMES:
		if _shot >= 0:
			_save(SHOTS[_shot][0])
		_shot += 1
		if _shot >= SHOTS.size():
			return true
		var s: Array = SHOTS[_shot]
		_view.call("set_hud_visible", false)
		_view.call("set_debug_geometry", s[4])
		_view.call("set_zoom", s[2])
		_view.call("place_at", s[1], s[5])
		if float(s[3]) >= 0.0:
			_view.call("cast", s[3])
		_shot_frame = _frames
	return false


func _save(shot_name: String) -> void:
	var image := root.get_viewport().get_texture().get_image()
	var size := image.get_size()
	var aspect := float(size.x) / float(size.y)
	if size.x > OUTPUT_SIZE.x and absf(aspect - float(OUTPUT_SIZE.x) / OUTPUT_SIZE.y) < 0.01:
		image.resize(OUTPUT_SIZE.x, OUTPUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var path := _out_dir.path_join("prerender_crypt_%s.png" % shot_name)
	var error := image.save_png(path)
	print("PRERENDER_CAPTURE %s %dx%d (window %dx%d) error=%d" % [
		path, image.get_width(), image.get_height(), size.x, size.y, error])
