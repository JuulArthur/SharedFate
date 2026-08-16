@tool
extends StaticBody2D

# Wooden crate that blocks the player, takes damage from attacks, and drops
# items when destroyed. Drop instances of `scenes/breakable_crate.tscn` into
# any level and configure `max_health` and `contained_items` in the inspector.
#
# Compatible with both player attack paths:
#   * Spacebar shape-query attack (calls `take_damage`).
#   * Click-to-attack target system (calls `receive_damage`).
# Both forward into the same internal `_apply_damage` so behaviour is uniform.

signal broken(crate: Node2D)

const SPLINTER_COUNT := 8
const SPLINTER_SPEED_MIN := 60.0
const SPLINTER_SPEED_MAX := 140.0
const SPLINTER_LIFETIME := 0.45

@export var max_health: int = 30
@export var contained_items: Array[Item] = []
@export var drop_spread: float = 18.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var _current_health: int = 0
var _broken: bool = false
var _sprite_idle_position: Vector2 = Vector2.ZERO
var _sprite_idle_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	if Engine.is_editor_hint():
		sprite.texture = CrateArt.intact_texture()
		return

	add_to_group("breakable")
	add_to_group("navmesh_source")

	collision_layer = 1
	collision_mask = 0

	_current_health = max_health
	sprite.texture = CrateArt.intact_texture()
	_sprite_idle_position = sprite.position
	_sprite_idle_scale = sprite.scale


# --- Damage entry points ---------------------------------------------------

func take_damage(amount: int) -> void:
	_apply_damage(amount)


func receive_damage(amount: int) -> void:
	_apply_damage(amount)


func is_alive() -> bool:
	return not _broken


# --- Internal --------------------------------------------------------------

func _apply_damage(amount: int) -> void:
	if _broken or amount <= 0:
		return

	_current_health = maxi(0, _current_health - amount)
	if _current_health == 0:
		_break_crate()
	else:
		_play_hit_animation()


func _play_hit_animation() -> void:
	if sprite == null:
		return

	sprite.modulate = Color(1.4, 0.85, 0.7, 1.0)
	sprite.position = _sprite_idle_position
	sprite.scale = _sprite_idle_scale

	var shake_offset := Vector2(randf_range(-2.0, 2.0), randf_range(-1.0, 1.0))
	var tween := create_tween()
	tween.tween_property(sprite, "position", _sprite_idle_position + shake_offset, 0.04)
	tween.tween_property(sprite, "position", _sprite_idle_position - shake_offset * 0.5, 0.05)
	tween.tween_property(sprite, "position", _sprite_idle_position, 0.05)
	tween.parallel().tween_property(sprite, "modulate", Color(1, 1, 1, 1), 0.18)


func _break_crate() -> void:
	if _broken:
		return
	_broken = true

	_spawn_splinters()
	_play_break_animation()
	_disable_collision()
	_drop_contained_items()
	broken.emit(self)


func _spawn_splinters() -> void:
	var splinter_texture := CrateArt.splinter_texture()
	for i in SPLINTER_COUNT:
		var splinter := Sprite2D.new()
		splinter.texture = splinter_texture
		splinter.position = sprite.position
		splinter.z_index = sprite.z_index
		add_sibling.call_deferred(splinter)
		splinter.global_position = global_position + sprite.position
		var angle := TAU * float(i) / float(SPLINTER_COUNT) + randf_range(-0.4, 0.4)
		var speed := randf_range(SPLINTER_SPEED_MIN, SPLINTER_SPEED_MAX)
		var target := splinter.global_position + Vector2.RIGHT.rotated(angle) * speed * SPLINTER_LIFETIME

		var splinter_tween := create_tween()
		splinter_tween.tween_property(splinter, "global_position", target, SPLINTER_LIFETIME)
		splinter_tween.parallel().tween_property(splinter, "rotation", randf_range(-PI, PI), SPLINTER_LIFETIME)
		splinter_tween.parallel().tween_property(splinter, "modulate:a", 0.0, SPLINTER_LIFETIME)
		splinter_tween.tween_callback(splinter.queue_free)


func _play_break_animation() -> void:
	if sprite == null:
		return

	var tween := create_tween()
	tween.tween_property(sprite, "scale", _sprite_idle_scale * Vector2(1.25, 0.85), 0.07)
	tween.tween_callback(_swap_to_broken_sprite)
	tween.tween_property(sprite, "scale", _sprite_idle_scale, 0.15)
	tween.parallel().tween_property(sprite, "modulate", Color(0.9, 0.85, 0.85, 1.0), 0.15)


func _swap_to_broken_sprite() -> void:
	if sprite == null:
		return
	sprite.texture = CrateArt.broken_texture()


func _disable_collision() -> void:
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	# Drop out of the navmesh source group so future rebakes treat this cell
	# as walkable again.
	remove_from_group("navmesh_source")


func _drop_contained_items() -> void:
	LootDropper.drop_items(self, contained_items, drop_spread)
