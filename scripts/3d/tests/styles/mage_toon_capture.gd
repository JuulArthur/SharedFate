extends SceneTree

## Windowed screenshot of the toon mage view (docs/style-study/mage_toon.md):
##
##     godot --path . --script res://scripts/3d/tests/styles/mage_toon_capture.gd -- <out.png>
##
## Loads scenes/3d/tests/styles/mage_toon_view.tscn, lets it run CAPTURE_FRAME
## frames (the walk check, then idle), saves the root viewport to <out.png>,
## scaled to 1600x900 when the window is larger, and quits. Needs a window: the
## headless renderer has no viewport texture to read.

const VIEW_SCENE := "res://scenes/3d/tests/styles/mage_toon_view.tscn"
const CAPTURE_FRAME := 120
const OUTPUT_SIZE := Vector2i(1600, 900)

var _frames := 0
var _out_path := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_out_path = args[0] if args.size() > 0 else "user://mage_toon_iso_godot.png"
	var packed := load(VIEW_SCENE) as PackedScene
	if packed == null:
		push_error("MAGE_TOON_CAPTURE: cannot load %s" % VIEW_SCENE)
		quit(1)
		return
	root.add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < CAPTURE_FRAME:
		return false
	var image := root.get_viewport().get_texture().get_image()
	var size := image.get_size()
	var aspect := float(size.x) / float(size.y)
	if size.x > OUTPUT_SIZE.x and absf(aspect - float(OUTPUT_SIZE.x) / OUTPUT_SIZE.y) < 0.01:
		image.resize(OUTPUT_SIZE.x, OUTPUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var error := image.save_png(_out_path)
	print("MAGE_TOON_CAPTURE %s %dx%d (window %dx%d) error=%d" % [
		_out_path, image.get_width(), image.get_height(), size.x, size.y, error])
	return true
