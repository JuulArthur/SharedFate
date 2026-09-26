class_name DireWolf3D
extends Enemy3D

## The dire wolf (`scenes/3d/enemies/dire_wolf_3d.tscn`): the wolf body scaled
## up and darkened, tougher and slower to swing. Every third bite is a heavy
## bite: HEAVY_BITE_MULT damage behind a longer, clearly marked wind-up (a
## `HEAVY` popup and the word in front of the counter hint). The pattern is a
## fixed count, never a roll, so fights and tests are repeatable.
##
## docs/enemy-roster.md.

## Every this many bites, the bite is heavy (the 3rd, 6th, ...).
const HEAVY_BITE_EVERY := 3
const HEAVY_BITE_MULT := 1.5
## The heavy bite's wind-up is this much longer than the normal one.
const HEAVY_WIND_UP_MULT := 1.6
const HEAVY_HINT := "HEAVY"
const HEAVY_COLOR := Color(1.0, 0.45, 0.2, 1.0)
const HEAVY_WIND_UP_TINT := Color(0.6, 0.12, 0.02, 1.0)
const HEAVY_POPUP_OFFSET := Vector3(0.0, 1.55, 0.0)

## Bites that reached their strike so far (aborted swings do not count).
var _bites_landed := 0
var _heavy_active := false


## True when the next swing that starts will be a heavy bite.
func is_next_bite_heavy() -> bool:
	return (_bites_landed + 1) % HEAVY_BITE_EVERY == 0


## True during a heavy bite's swing.
func is_heavy_bite_active() -> bool:
	return _heavy_active


func get_bites_landed() -> int:
	return _bites_landed


func _begin_attack_variant(_target_node: Node3D) -> void:
	_heavy_active = is_next_bite_heavy()
	if _heavy_active:
		CombatFx.popup_text(global_position + HEAVY_POPUP_OFFSET, HEAVY_HINT, HEAVY_COLOR, 18)


func _end_attack_variant(resolved: bool) -> void:
	if resolved:
		_bites_landed += 1
	_heavy_active = false


func _attack_wind_up_seconds(turn_mode: bool) -> float:
	var seconds := super(turn_mode)
	return seconds * HEAVY_WIND_UP_MULT if _heavy_active else seconds


func _attack_base_damage() -> int:
	if _heavy_active:
		return roundi(float(attack_damage) * HEAVY_BITE_MULT)
	return attack_damage


func _attack_hint_prefix() -> String:
	return HEAVY_HINT if _heavy_active else ""


func _play_wind_up(target_node: Node3D, seconds: float) -> void:
	if _heavy_active:
		# A deeper crouch under a hotter glow, so the heavy bite reads apart.
		_flash_model(HEAVY_WIND_UP_TINT, seconds)
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(_model, "position",
			_model_idle_position + Vector3(0.0, 0.0, WIND_UP_PULL_M * 1.8), seconds) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(_model, "scale", _model_idle_scale * Vector3(1.04, 0.9, 0.8), seconds)
		await tween.finished
		return
	await super(target_node, seconds)
