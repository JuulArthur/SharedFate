extends Area2D

# Drop one of these on a level to send the player into another scene when
# they walk into it. Set target_scene_path to the next scene and
# target_spawn_name to the Spawn_<name> node in that scene where the
# player should appear.

@export_file("*.tscn") var target_scene_path: String = ""
@export var target_spawn_name: StringName = &"default"

var _triggered := false


func _ready() -> void:
	monitoring = true
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	if _triggered:
		return
	if target_scene_path == "":
		push_warning("LevelTransition %s has no target_scene_path set." % name)
		return
	if not body.is_in_group("player"):
		return

	_triggered = true
	LevelLoader.change_level(target_scene_path, target_spawn_name)
