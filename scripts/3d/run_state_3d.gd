class_name RunState3D
extends RefCounted

## What the Bound Three carry from one level to the next (docs/level-flow.md).
##
## A level is its own scene, and everything the body has - level and XP,
## health, the soul in control, inventory and equipment, attributes, mana and
## stamina, skill cards and forged skills, buffs - lives on the player node in
## that scene. Before a level change the coordinator stores that state here
## (`Player3D.get_run_state`), with the entry point to arrive at; the next
## level's coordinator takes both in `_ready` and puts them back
## (`Player3D.apply_run_state`, an `Entry_<id>` node).
##
## Static variables outlive the scene tree's scene changes, so no autoload is
## needed. They last one session: this is the seam a save game will write and
## read later.

static var _player_state: Dictionary = {}
static var _entry: StringName = &""
static var _from_level: String = ""


## Keeps `player_state` for the next level, to arrive at `entry` there.
static func store(player_state: Dictionary, entry: StringName, from_level: String = "") -> void:
	_player_state = player_state
	_entry = entry
	_from_level = from_level


static func has_pending() -> bool:
	return not _player_state.is_empty() or _entry != &""


## The stored player state, once: the next call returns an empty dictionary.
static func take_player_state() -> Dictionary:
	var state := _player_state
	_player_state = {}
	return state


## The entry point to arrive at, once: the next call returns &"".
static func take_entry() -> StringName:
	var entry := _entry
	_entry = &""
	return entry


## The level the body came from ("" on a fresh start), for a level that wants
## to say "back from ...".
static func last_level() -> String:
	return _from_level


static func clear() -> void:
	_player_state = {}
	_entry = &""
	_from_level = ""
