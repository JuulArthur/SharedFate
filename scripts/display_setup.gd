extends Node

# Autoloaded singleton. Owns the game window: opens it at a usable size on
# launch and handles the fullscreen toggle.
#
# The game renders at a fixed design resolution (`window/size/viewport_*` in
# project.godot) and `window/stretch/mode="canvas_items"` scales *everything* --
# world and UI alike -- up to the real window size. So a bigger window means
# bigger, more readable text for free, and no UI code has to know the
# resolution. The world framing is unchanged no matter how big the window gets,
# because the design resolution (and therefore how much of the map fits on
# screen) stays the same.
#
# Press F11 or Alt+Enter to toggle fullscreen at any time.

# Reference size for the window. Its aspect ratio is what the window keeps; the
# actual size is scaled up or down so the window fills the desktop without
# covering it entirely. Scaling up matters on HiDPI screens, where a window
# measured in render pixels covers far fewer desktop points than the number
# suggests.
const TARGET_WINDOW_SIZE := Vector2i(2560, 1440)
# Share of the usable desktop the launch window may occupy.
const MAX_SCREEN_FRACTION := 0.9
# How far the granted window size may differ from the requested one before we
# treat the window as locked rather than merely rounded by the compositor.
const SIZE_TOLERANCE_PX := 8
const FULLSCREEN_ACTION: StringName = &"toggle_fullscreen"


func _ready() -> void:
	# Keep reacting to F11 even while gameplay is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_fullscreen_action()
	_resize_window_to_screen()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(FULLSCREEN_ACTION):
		return
	get_viewport().set_input_as_handled()
	toggle_fullscreen()


func toggle_fullscreen() -> void:
	var is_fullscreen := DisplayServer.window_get_mode() in [
		DisplayServer.WINDOW_MODE_FULLSCREEN,
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
	]
	if is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_resize_window_to_screen()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _resize_window_to_screen() -> void:
	# Never fight a window the player (or the editor's run settings) already put
	# into fullscreen or maximized.
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return

	var screen := DisplayServer.window_get_current_screen()
	# The usable rect excludes menu bar / taskbar / dock, but not our title bar.
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var decorations := DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	var available := Vector2(usable.size - decorations) * MAX_SCREEN_FRACTION

	# Largest window of the target shape that still fits the desktop.
	var fit := minf(
		available.x / float(TARGET_WINDOW_SIZE.x),
		available.y / float(TARGET_WINDOW_SIZE.y)
	)
	var size := Vector2i(Vector2(TARGET_WINDOW_SIZE) * fit)

	DisplayServer.window_set_size(size)

	# The compositor rounds the request to whole device pixels, so compare
	# loosely. A wildly different size means the window is locked: in practice
	# the editor is running the game embedded in its Game panel, which owns the
	# window rect and refuses ours. Don't reposition a window we couldn't
	# resize, and say why -- the engine's own message ("Embedded window can't be
	# resized.") doesn't hint at the fix.
	var granted := DisplayServer.window_get_size()
	if absi(granted.x - size.x) > SIZE_TOLERANCE_PX or absi(granted.y - size.y) > SIZE_TOLERANCE_PX:
		print("DisplaySetup: window is locked at %s, wanted %s. " % [granted, size]
			+ "Turn off 'Embed Game on Next Play' in the editor's Game tab "
			+ "to run in a full-size window.")
		return

	# Center on the usable area, leaving room above for the title bar.
	var window_position := usable.position + (usable.size - decorations - granted) / 2
	window_position.y += decorations.y
	DisplayServer.window_set_position(window_position)


func _ensure_fullscreen_action() -> void:
	# Registered in code (same pattern as `toggle_inventory` in main.gd) so the
	# binding lives next to the behaviour it drives.
	if not InputMap.has_action(FULLSCREEN_ACTION):
		InputMap.add_action(FULLSCREEN_ACTION)

	var f11 := InputEventKey.new()
	f11.physical_keycode = KEY_F11
	var alt_enter := InputEventKey.new()
	alt_enter.physical_keycode = KEY_ENTER
	alt_enter.alt_pressed = true

	for wanted in [f11, alt_enter]:
		var already_bound := false
		for existing in InputMap.action_get_events(FULLSCREEN_ACTION):
			if existing is InputEventKey \
					and existing.physical_keycode == wanted.physical_keycode \
					and existing.alt_pressed == wanted.alt_pressed:
				already_bound = true
				break
		if not already_bound:
			InputMap.action_add_event(FULLSCREEN_ACTION, wanted)
