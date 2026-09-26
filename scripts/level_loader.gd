extends Node

# Autoloaded singleton. Handles scene changes between levels and remembers
# which spawn point the player should appear at in the next scene.
#
# Usage:
#   LevelLoader.change_level("res://scenes/castle_level.tscn", &"from_main")
#
# A level scene should contain a Node2D named "Spawn_<name>" (e.g.
# "Spawn_from_main"). The player is moved to that spawn automatically.
# Levels may also call LevelLoader.apply_spawn(self) in _ready if they
# want the spawn to be applied eagerly (before any other code runs).

const PLAYER_GROUP: StringName = &"player"
const SPAWN_NODE_PREFIX := "Spawn_"

var pending_spawn_name: StringName = &""


func change_level(scene_path: String, spawn_name: StringName = &"default") -> void:
	pending_spawn_name = spawn_name
	call_deferred("_change_scene_deferred", scene_path)


func _change_scene_deferred(scene_path: String) -> void:
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("LevelLoader: failed to change scene to %s (err %d)" % [scene_path, err])
		return

	await get_tree().process_frame

	var root := get_tree().current_scene
	if root != null:
		apply_spawn(root)


func apply_spawn(scene_root: Node) -> void:
	if pending_spawn_name == &"":
		return

	var spawn_node_name := SPAWN_NODE_PREFIX + String(pending_spawn_name)
	var spawn_node := scene_root.find_child(spawn_node_name, true, false)
	var spawn := spawn_node as Node2D
	# 3D levels (docs/3d-port-contracts.md, section 9) author their spawn
	# points as Node3D; the branch below moves a Node3D player onto one.
	var spawn_3d := spawn_node as Node3D
	var requested_spawn_name := pending_spawn_name
	pending_spawn_name = &""

	if spawn == null and spawn_3d == null:
		push_warning("LevelLoader: no node named %s found for spawn %s" % [spawn_node_name, requested_spawn_name])
		return

	var player := _find_player(scene_root)
	if player == null:
		return

	if spawn_3d != null:
		if player.has_method("snap_to"):
			player.call("snap_to", spawn_3d.global_position)
		elif player is Node3D:
			(player as Node3D).global_position = spawn_3d.global_position
		else:
			push_warning("LevelLoader: spawn %s is a Node3D but the player is not" % spawn_node_name)
		return

	var player_2d := player as Node2D
	if player_2d == null:
		return

	if player_2d.has_method("snap_to"):
		player_2d.call("snap_to", spawn.global_position)
	else:
		player_2d.global_position = spawn.global_position


# The first node in the player group: a Node2D in the 2D levels, a Node3D in
# the 3D port. Callers cast to the dimension they need.
func _find_player(scene_root: Node) -> Node:
	var tree := scene_root.get_tree()
	if tree == null:
		return null
	var players := tree.get_nodes_in_group(PLAYER_GROUP)
	if players.is_empty():
		return null
	return players[0] as Node
