extends SceneTree

## Builds `scenes/3d/levels/hollow_road.tscn`, the placeholder second level
## that proves the level flow (docs/level-flow.md): a copy of the test arena
## (its layout, three wolves and its baked navmesh) without the acceptance-test
## node, with an entry point `Entry_from_wilds` and a LevelExit3D back to the
## Wilds' `Entry_from_road`. It stands in for a real level until level 1 is
## built (docs/level-1-design.md).
##
##   godot --headless --path . --script res://tools/build_hollow_road_placeholder.gd
##
## Prints BUILD OK. Untyped on purpose: a --script tool compiles before the
## autoloads exist, so it must not name classes that use them.

const ARENA_PATH := "res://scenes/3d/arena.tscn"
const OUTPUT_PATH := "res://scenes/3d/levels/hollow_road.tscn"
const EXIT_SCRIPT_PATH := "res://scripts/3d/world/level_exit_3d.gd"
const WILDS_PATH := "res://scenes/3d/wilds.tscn"

## The arena's spawn is (-9, 0, 0); the way back stands 3 m behind it, clear
## of the wolves' 5 m rings (the nearest wolf is at (-2, 0, 5)).
const ENTRY_AT := Vector3(-9.0, 0.0, 0.0)
const EXIT_AT := Vector3(-10.5, 0.0, 2.6)


func _initialize() -> void:
	var ok := _build()
	print("BUILD OK" if ok else "BUILD FAILED")
	quit(0 if ok else 1)


func _build() -> bool:
	var arena := load(ARENA_PATH) as PackedScene
	if arena == null:
		push_error("build_hollow_road_placeholder: cannot load %s" % ARENA_PATH)
		return false
	var root := arena.instantiate() as Node3D
	root.name = "HollowRoad"
	# A full scene of its own, not a scene inheriting the arena.
	root.scene_file_path = ""
	var smoke := root.get_node_or_null("IntegrationSmoke")
	if smoke != null:
		root.remove_child(smoke)
		smoke.free()
	root.set("story_chapter_id", &"")
	root.set("spawn_test_loot", false)
	root.set("level_display_name", "The Hollow Road (placeholder)")

	var entry := Node3D.new()
	entry.name = "Entry_from_wilds"
	entry.position = ENTRY_AT
	root.add_child(entry)
	entry.owner = root

	var exit_node := Node3D.new()
	exit_node.set_script(load(EXIT_SCRIPT_PATH))
	exit_node.name = "ExitToWilds"
	exit_node.position = EXIT_AT
	exit_node.set("target_scene", WILDS_PATH)
	exit_node.set("target_entry", &"from_road")
	exit_node.set("label", "To the Wilds")
	root.add_child(exit_node)
	exit_node.owner = root

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		push_error("build_hollow_road_placeholder: pack failed (%d)" % pack_error)
		return false
	var save_error := ResourceSaver.save(packed, OUTPUT_PATH)
	root.free()
	if save_error != OK:
		push_error("build_hollow_road_placeholder: save failed (%d)" % save_error)
		return false
	return true
