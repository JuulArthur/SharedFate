extends Node2D

# Hand-authored forest level. Add ForestTree and ForestTent instances under
# the Trees / Tents containers in the editor. On ready the NavigationRegion
# bakes a polygon over the playable area and subtracts each tree's static
# collider so click-to-move pathfinds around them.

const FOREST_WIDTH := 2400.0
const FOREST_HEIGHT := 1600.0
const NAVMESH_SOURCE_GROUP: StringName = &"navmesh_source"

@export var camera_follow_speed: float = 6.0
# Chapter read in the story book when this level opens (once per session).
# Authored in StoryLibrary; leave empty for no narration.
@export var story_chapter_id: StringName = StoryLibrary.FOREST

@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $Camera2D
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var trees_root: Node2D = $Trees
@onready var forest_walls_root: Node2D = $ForestWalls


func _ready() -> void:
	_setup_nav_region()

	# Wait one physics frame so newly entered static bodies (trees) have
	# their collision shapes registered before the nav polygon is baked.
	await get_tree().physics_frame
	nav_region.bake_navigation_polygon(false)

	LevelLoader.apply_spawn(self)
	if camera != null and player != null:
		camera.global_position = player.global_position
		camera.make_current()
	StoryBook.show_chapter_once(StoryLibrary.chapter(story_chapter_id))


func _process(delta: float) -> void:
	if camera == null or player == null:
		return
	var weight := clampf(delta * camera_follow_speed, 0.0, 1.0)
	camera.global_position = camera.global_position.lerp(player.global_position, weight)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if player == null:
			return
		var click_position := get_global_mouse_position()
		if player.has_method("set_navigation_target"):
			player.call("set_navigation_target", click_position)


func _setup_nav_region() -> void:
	var nav_poly := NavigationPolygon.new()
	var half_w := FOREST_WIDTH * 0.5
	var half_h := FOREST_HEIGHT * 0.5
	var outline := PackedVector2Array([
		Vector2(-half_w, -half_h),
		Vector2(half_w, -half_h),
		Vector2(half_w, half_h),
		Vector2(-half_w, half_h),
	])
	nav_poly.add_outline(outline)
	nav_poly.agent_radius = 12.0
	nav_poly.parsed_geometry_type = NavigationPolygon.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_poly.parsed_collision_mask = 1
	nav_poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_poly.source_geometry_group_name = NAVMESH_SOURCE_GROUP
	nav_region.navigation_polygon = nav_poly
	trees_root.add_to_group(NAVMESH_SOURCE_GROUP)
	forest_walls_root.add_to_group(NAVMESH_SOURCE_GROUP)
