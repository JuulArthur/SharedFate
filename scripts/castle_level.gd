extends Node2D

# Level script for the hand-drawn Castle level. Click-to-move uses the same
# NavigationAgent2D pathfinding as the main map (via set_navigation_target).

@export var camera_follow_speed: float = 6.0
# Chapter read in the story book when this level opens (once per session).
# Authored in StoryLibrary; leave empty for no narration.
@export var story_chapter_id: StringName = StoryLibrary.CASTLE

@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $Camera2D


func _ready() -> void:
	LevelLoader.apply_spawn(self)
	if camera != null:
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
