extends SceneTree

## WP7: offline navmesh bake for scenes/3d/arena.tscn (docs/3d-port-contracts.md
## section 9; "try to ship a baked mesh" in the WP7 package brief).
##
## Instances the arena, waits a few frames so every prop_3d.gd _ready() has
## relabelled its imported colliders onto layer 4 (props) before the region
## reads geometry, disables the coordinator's own runtime bake for this run
## (main_3d.gd's _ready() would otherwise start a second, threaded bake on the
## same region the moment it is added to the tree, racing this script's
## synchronous one), bakes synchronously with
## NavigationRegion3D.bake_navigation_mesh(false), and saves the result to
## res://scenes/3d/arena_navmesh.tres so arena.tscn can reference it as a
## pre-baked ext_resource instead of relying on WP4's runtime bake fallback.
##
## Run: godot --headless --path . --script res://tools/bake_arena_navmesh.gd

const ARENA_SCENE_PATH := "res://scenes/3d/arena.tscn"
const OUTPUT_PATH := "res://scenes/3d/arena_navmesh.tres"
const SETTLE_PROCESS_FRAMES := 10
const SETTLE_PHYSICS_FRAMES := 4


## MainLoop._initialize(), not the GDScript constructor: SceneTree registers
## the project's autoloads as part of its own engine-side init step, which
## runs after this script object is constructed but before _initialize() is
## called. main_3d.gd (arena.tscn's root script) resolves CombatFx, LootMenu,
## StoryBook and ItemFactory as bare autoload identifiers at compile time, so
## load()-ing arena.tscn from _init() fails with "Identifier not found" (the
## same failure --check-only hits, docs/deviations/wp4.md #1) even though this
## is a plain --script run; _initialize() is the fix.
func _initialize() -> void:
	var packed: PackedScene = load(ARENA_SCENE_PATH)
	if packed == null:
		push_error("bake_arena_navmesh: could not load %s" % ARENA_SCENE_PATH)
		quit(1)
		return
	var arena := packed.instantiate() as Node3D
	if arena == null:
		push_error("bake_arena_navmesh: %s root is not a Node3D" % ARENA_SCENE_PATH)
		quit(1)
		return
	# This script bakes explicitly below; stop the coordinator's own _ready()
	# from starting a second, threaded bake on the same region as soon as it
	# is added to the tree (docs/3d-port-contracts.md section 9,
	# bake_navmesh_if_empty).
	arena.set("bake_navmesh_if_empty", false)

	var region := arena.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if region == null:
		push_error("bake_arena_navmesh: no NavigationRegion3D in %s" % ARENA_SCENE_PATH)
		quit(1)
		return

	root.add_child(arena)

	for _i in range(SETTLE_PROCESS_FRAMES):
		await process_frame
	for _i in range(SETTLE_PHYSICS_FRAMES):
		await physics_frame

	_bake(region)


func _bake(region: NavigationRegion3D) -> void:
	var mesh := region.navigation_mesh
	if mesh == null:
		push_error("bake_arena_navmesh: NavigationRegion3D has no NavigationMesh resource to bake into")
		quit(1)
		return

	region.bake_navigation_mesh(false)

	var polygon_count := mesh.get_polygon_count()
	print("[bake_arena_navmesh] baked %d polygons" % polygon_count)
	if polygon_count <= 0:
		push_warning("[bake_arena_navmesh] navmesh has no polygons after a synchronous bake")
		quit(1)
		return

	var err := ResourceSaver.save(mesh, OUTPUT_PATH)
	if err != OK:
		push_error("[bake_arena_navmesh] ResourceSaver.save failed: %d" % err)
		quit(1)
		return

	print("BAKE OK: %s (%d polygons)" % [OUTPUT_PATH, polygon_count])
	quit(0)
