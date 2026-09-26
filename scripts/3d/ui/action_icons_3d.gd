class_name ActionIcons3D
extends RefCounted

## Vector glyphs for the action bar, drawn with CanvasItem calls so every slot
## scales cleanly and takes its ability's colour. `draw_icon` is called from a
## Control's `_draw`; an unknown key falls back to the name's first letter.
##
## Glyphs are authored on a unit square (0..1, y down) and mapped into `rect`.

const OUTLINE := Color(0.02, 0.02, 0.02, 0.85)


static func draw_icon(ci: CanvasItem, rect: Rect2, key: StringName, color: Color, fallback: String = "") -> void:
	var g := _Glyph.new(ci, rect, color)
	match key:
		&"melee":
			_sword(g)
		&"throw":
			_throw(g)
		&"block":
			_shield(g, false)
		&"wait":
			_hourglass(g)
		&"end_turn":
			_end_turn(g)
		&"arcane_burst":
			_burst(g)
		&"frost_snare":
			_snowflake(g, Vector2(0.5, 0.5), 0.34)
		&"sneak":
			_sneak(g)
		&"skill_tree":
			_book(g)
		&"shield_bash":
			_shield(g, true)
		&"cleave":
			_cleave(g)
		&"second_wind":
			_heart(g)
		&"charge":
			_charge(g)
		&"backstab":
			_backstab(g)
		&"shadowstep":
			_shadowstep(g)
		&"poison_blade":
			_poison(g)
		&"set_snare":
			_trap(g)
		&"smoke_bomb":
			_smoke(g)
		&"blink":
			_blink(g)
		&"fireball":
			_fireball(g)
		&"chain_lightning":
			_bolt(g)
		&"frost_nova":
			_nova(g)
		&"distract":
			_pebble(g)
		_:
			_letter(ci, rect, color, fallback)


## Maps unit-square coordinates into the slot and wraps the draw calls.
class _Glyph:
	var ci: CanvasItem
	var rect: Rect2
	var color: Color

	func _init(canvas: CanvasItem, area: Rect2, tint: Color) -> void:
		ci = canvas
		rect = area
		color = tint

	func p(x: float, y: float) -> Vector2:
		return rect.position + Vector2(x, y) * rect.size

	func s(v: float) -> float:
		return v * minf(rect.size.x, rect.size.y)

	func line(a: Vector2, b: Vector2, width: float, tint: Color = color) -> void:
		ci.draw_line(p(a.x, a.y), p(b.x, b.y), tint, s(width), true)

	func poly(points: PackedVector2Array, tint: Color = color) -> void:
		var mapped := PackedVector2Array()
		for point in points:
			mapped.append(p(point.x, point.y))
		ci.draw_colored_polygon(mapped, tint)

	func outline(points: PackedVector2Array, width: float, tint: Color = color) -> void:
		var mapped := PackedVector2Array()
		for point in points:
			mapped.append(p(point.x, point.y))
		mapped.append(mapped[0])
		ci.draw_polyline(mapped, tint, s(width), true)

	func circle(c: Vector2, r: float, tint: Color = color) -> void:
		ci.draw_circle(p(c.x, c.y), s(r), tint)

	func ring(c: Vector2, r: float, width: float, tint: Color = color, from: float = 0.0, to: float = TAU) -> void:
		ci.draw_arc(p(c.x, c.y), s(r), from, to, 32, tint, s(width), true)


static func _sword(g: _Glyph) -> void:
	# Blade from lower left to upper right, crossguard and pommel.
	g.poly(PackedVector2Array([Vector2(0.80, 0.14), Vector2(0.86, 0.20), Vector2(0.40, 0.66), Vector2(0.34, 0.60)]))
	g.line(Vector2(0.25, 0.55), Vector2(0.45, 0.75), 0.07)
	g.line(Vector2(0.36, 0.64), Vector2(0.20, 0.80), 0.07, g.color.darkened(0.35))
	g.circle(Vector2(0.18, 0.82), 0.05)


static func _throw(g: _Glyph) -> void:
	# A dagger in flight with speed lines behind it.
	g.poly(PackedVector2Array([Vector2(0.88, 0.40), Vector2(0.58, 0.33), Vector2(0.58, 0.47)]))
	g.line(Vector2(0.58, 0.28), Vector2(0.58, 0.52), 0.06)
	g.line(Vector2(0.58, 0.40), Vector2(0.44, 0.40), 0.07, g.color.darkened(0.35))
	var faint := Color(g.color, 0.55)
	g.line(Vector2(0.14, 0.34), Vector2(0.36, 0.34), 0.04, faint)
	g.line(Vector2(0.08, 0.46), Vector2(0.34, 0.46), 0.04, faint)
	g.line(Vector2(0.18, 0.58), Vector2(0.38, 0.58), 0.04, faint)


static func _shield_points() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.50, 0.12), Vector2(0.80, 0.22), Vector2(0.77, 0.52),
		Vector2(0.50, 0.88), Vector2(0.23, 0.52), Vector2(0.20, 0.22)])


static func _shield(g: _Glyph, impact: bool) -> void:
	var points := _shield_points()
	if impact:
		for i in range(points.size()):
			points[i] = points[i] * 0.82 + Vector2(0.0, 0.06)
	g.poly(points, Color(g.color, 0.30))
	g.outline(points, 0.06)
	g.line(points[0], (points[3] + points[0]) * 0.5 + Vector2(0, 0.14), 0.05)
	if impact:
		# Impact sparks above the rim.
		g.line(Vector2(0.50, 0.06), Vector2(0.50, 0.00), 0.05)
		g.line(Vector2(0.30, 0.10), Vector2(0.24, 0.04), 0.05)
		g.line(Vector2(0.70, 0.10), Vector2(0.76, 0.04), 0.05)


static func _hourglass(g: _Glyph) -> void:
	g.line(Vector2(0.26, 0.14), Vector2(0.74, 0.14), 0.07)
	g.line(Vector2(0.26, 0.86), Vector2(0.74, 0.86), 0.07)
	g.outline(PackedVector2Array([Vector2(0.32, 0.18), Vector2(0.68, 0.18), Vector2(0.53, 0.50),
		Vector2(0.68, 0.82), Vector2(0.32, 0.82), Vector2(0.47, 0.50)]), 0.05)
	g.poly(PackedVector2Array([Vector2(0.36, 0.80), Vector2(0.64, 0.80), Vector2(0.50, 0.62)]), Color(g.color, 0.7))


static func _end_turn(g: _Glyph) -> void:
	# A curved arrow coming round: the turn passes.
	g.ring(Vector2(0.48, 0.52), 0.26, 0.08, g.color, PI * 0.95, PI * 2.25)
	var tip := Vector2(0.48, 0.52) + Vector2(cos(PI * 2.25), sin(PI * 2.25)) * 0.26
	g.poly(PackedVector2Array([tip + Vector2(0.14, -0.02), tip + Vector2(-0.06, -0.12), tip + Vector2(-0.02, 0.12)]))


static func _burst(g: _Glyph) -> void:
	var c := Vector2(0.5, 0.5)
	var points := PackedVector2Array()
	for i in range(16):
		var r := 0.38 if i % 2 == 0 else 0.16
		var a := TAU * float(i) / 16.0 - PI * 0.5
		points.append(c + Vector2(cos(a), sin(a)) * r)
	g.poly(points, Color(g.color, 0.85))
	g.circle(c, 0.09, Color(1, 1, 1, 0.9))


static func _snowflake(g: _Glyph, c: Vector2, r: float) -> void:
	for i in range(3):
		var a := PI * float(i) / 3.0 + PI * 0.5
		var dir := Vector2(cos(a), sin(a))
		g.line(c - dir * r, c + dir * r, 0.05)
		for sgn in [-1.0, 1.0]:
			var tip: Vector2 = c + dir * r * 0.62 * sgn
			var side := dir.rotated(PI * 0.25 * sgn)
			var side2 := dir.rotated(-PI * 0.25 * sgn)
			g.line(tip, tip + side * r * 0.3 * sgn, 0.04)
			g.line(tip, tip + side2 * r * 0.3 * sgn, 0.04)


static func _sneak(g: _Glyph) -> void:
	# A hooded head, face in shadow, two eyes glinting.
	var hood := PackedVector2Array([Vector2(0.50, 0.08), Vector2(0.74, 0.22), Vector2(0.84, 0.50),
		Vector2(0.90, 0.90), Vector2(0.10, 0.90), Vector2(0.16, 0.50), Vector2(0.26, 0.22)])
	g.poly(hood, Color(g.color, 0.45))
	g.outline(hood, 0.05)
	var face := PackedVector2Array()
	for i in range(20):
		var a := TAU * float(i) / 20.0
		face.append(Vector2(0.50, 0.58) + Vector2(cos(a) * 0.20, sin(a) * 0.24))
	g.poly(face, Color(0.03, 0.02, 0.05, 1.0))
	g.circle(Vector2(0.42, 0.56), 0.035)
	g.circle(Vector2(0.58, 0.56), 0.035)


static func _book(g: _Glyph) -> void:
	g.poly(PackedVector2Array([Vector2(0.14, 0.26), Vector2(0.48, 0.32), Vector2(0.48, 0.82), Vector2(0.14, 0.76)]), Color(g.color, 0.35))
	g.poly(PackedVector2Array([Vector2(0.52, 0.32), Vector2(0.86, 0.26), Vector2(0.86, 0.76), Vector2(0.52, 0.82)]), Color(g.color, 0.35))
	g.outline(PackedVector2Array([Vector2(0.14, 0.26), Vector2(0.50, 0.32), Vector2(0.86, 0.26),
		Vector2(0.86, 0.76), Vector2(0.50, 0.82), Vector2(0.14, 0.76)]), 0.05)
	g.line(Vector2(0.50, 0.32), Vector2(0.50, 0.82), 0.04)
	# A small star above the spine: something to learn.
	g.line(Vector2(0.50, 0.06), Vector2(0.50, 0.22), 0.04)
	g.line(Vector2(0.42, 0.14), Vector2(0.58, 0.14), 0.04)


static func _cleave(g: _Glyph) -> void:
	g.ring(Vector2(0.50, 0.62), 0.36, 0.10, g.color, PI * 1.08, PI * 1.92)
	g.ring(Vector2(0.50, 0.62), 0.22, 0.05, Color(g.color, 0.55), PI * 1.15, PI * 1.85)
	g.line(Vector2(0.50, 0.62), Vector2(0.50, 0.86), 0.07, g.color.darkened(0.35))


static func _heart(g: _Glyph) -> void:
	g.circle(Vector2(0.36, 0.40), 0.16)
	g.circle(Vector2(0.64, 0.40), 0.16)
	g.poly(PackedVector2Array([Vector2(0.21, 0.46), Vector2(0.79, 0.46), Vector2(0.50, 0.82)]))
	g.line(Vector2(0.50, 0.32), Vector2(0.50, 0.60), 0.06, OUTLINE)
	g.line(Vector2(0.36, 0.46), Vector2(0.64, 0.46), 0.06, OUTLINE)


static func _charge(g: _Glyph) -> void:
	g.poly(PackedVector2Array([Vector2(0.88, 0.50), Vector2(0.60, 0.26), Vector2(0.60, 0.40),
		Vector2(0.30, 0.40), Vector2(0.30, 0.60), Vector2(0.60, 0.60), Vector2(0.60, 0.74)]))
	var faint := Color(g.color, 0.55)
	g.line(Vector2(0.08, 0.36), Vector2(0.22, 0.36), 0.04, faint)
	g.line(Vector2(0.04, 0.50), Vector2(0.22, 0.50), 0.04, faint)
	g.line(Vector2(0.08, 0.64), Vector2(0.22, 0.64), 0.04, faint)


static func _backstab(g: _Glyph) -> void:
	# A dagger point-down with a drop of blood.
	g.poly(PackedVector2Array([Vector2(0.44, 0.40), Vector2(0.56, 0.40), Vector2(0.50, 0.88)]))
	g.line(Vector2(0.32, 0.40), Vector2(0.68, 0.40), 0.06)
	g.line(Vector2(0.50, 0.40), Vector2(0.50, 0.16), 0.08, g.color.darkened(0.35))
	g.circle(Vector2(0.72, 0.70), 0.06, Color(0.85, 0.2, 0.2, 1.0))


static func _shadowstep(g: _Glyph) -> void:
	# Footprints fading from solid to ghost.
	var steps := [Vector2(0.24, 0.78), Vector2(0.42, 0.60), Vector2(0.58, 0.44), Vector2(0.76, 0.26)]
	for i in range(steps.size()):
		var alpha := 0.35 + 0.65 * float(i) / float(steps.size() - 1)
		var offset := Vector2(-0.05, 0.0) if i % 2 == 0 else Vector2(0.05, 0.0)
		g.circle(steps[i] + offset, 0.075, Color(g.color, alpha))
		g.circle(steps[i] + offset + Vector2(0.0, -0.09), 0.04, Color(g.color, alpha))


static func _poison(g: _Glyph) -> void:
	# A drop over a blade edge.
	g.circle(Vector2(0.50, 0.58), 0.20)
	g.poly(PackedVector2Array([Vector2(0.50, 0.14), Vector2(0.67, 0.50), Vector2(0.33, 0.50)]))
	g.circle(Vector2(0.44, 0.56), 0.05, Color(1, 1, 1, 0.55))
	g.line(Vector2(0.14, 0.88), Vector2(0.86, 0.88), 0.05, g.color.darkened(0.3))


static func _trap(g: _Glyph) -> void:
	# Jaws of a snare, teeth up.
	g.ring(Vector2(0.50, 0.50), 0.30, 0.06, g.color, 0.0, PI)
	var teeth := PackedVector2Array()
	for i in range(6):
		var x := 0.22 + 0.112 * float(i)
		teeth.append(Vector2(x, 0.56))
		teeth.append(Vector2(x + 0.056, 0.36))
	teeth.append(Vector2(0.78, 0.56))
	g.ci.draw_polyline(_map(g, teeth), g.color, g.s(0.045), true)
	g.line(Vector2(0.14, 0.56), Vector2(0.86, 0.56), 0.05)
	g.circle(Vector2(0.50, 0.80), 0.06)


static func _smoke(g: _Glyph) -> void:
	var soft := Color(g.color, 0.8)
	g.circle(Vector2(0.34, 0.58), 0.17, soft)
	g.circle(Vector2(0.56, 0.46), 0.21, soft)
	g.circle(Vector2(0.70, 0.62), 0.15, soft)
	g.poly(PackedVector2Array([Vector2(0.20, 0.62), Vector2(0.84, 0.62), Vector2(0.84, 0.76), Vector2(0.20, 0.76)]), soft)
	g.circle(Vector2(0.30, 0.26), 0.06, Color(g.color, 0.5))


static func _blink(g: _Glyph) -> void:
	# A dashed jump to a sparkle.
	var faint := Color(g.color, 0.6)
	g.line(Vector2(0.14, 0.80), Vector2(0.26, 0.68), 0.05, faint)
	g.line(Vector2(0.34, 0.60), Vector2(0.46, 0.48), 0.05, faint)
	g.circle(Vector2(0.14, 0.82), 0.05, faint)
	var c := Vector2(0.68, 0.32)
	g.poly(PackedVector2Array([c + Vector2(0, -0.22), c + Vector2(0.06, -0.06), c + Vector2(0.22, 0),
		c + Vector2(0.06, 0.06), c + Vector2(0, 0.22), c + Vector2(-0.06, 0.06),
		c + Vector2(-0.22, 0), c + Vector2(-0.06, -0.06)]))


static func _fireball(g: _Glyph) -> void:
	g.poly(PackedVector2Array([Vector2(0.50, 0.08), Vector2(0.70, 0.40), Vector2(0.78, 0.30),
		Vector2(0.80, 0.60), Vector2(0.50, 0.90), Vector2(0.20, 0.60), Vector2(0.26, 0.34), Vector2(0.36, 0.44)]))
	g.circle(Vector2(0.50, 0.64), 0.16, Color(1.0, 0.85, 0.4, 1.0))


static func _bolt(g: _Glyph) -> void:
	g.poly(PackedVector2Array([Vector2(0.60, 0.06), Vector2(0.26, 0.54), Vector2(0.48, 0.54),
		Vector2(0.38, 0.94), Vector2(0.76, 0.40), Vector2(0.54, 0.40)]))


static func _nova(g: _Glyph) -> void:
	g.ring(Vector2(0.5, 0.5), 0.40, 0.05, Color(g.color, 0.6))
	_snowflake(g, Vector2(0.5, 0.5), 0.24)


static func _pebble(g: _Glyph) -> void:
	# A stone tossed along an arc, with a ripple where it lands.
	var faint := Color(g.color, 0.55)
	g.ring(Vector2(0.50, 0.80), 0.36, 0.04, faint, PI * 1.15, PI * 1.62)
	g.circle(Vector2(0.58, 0.40), 0.11)
	g.ring(Vector2(0.62, 0.74), 0.08, 0.035, faint, PI, TAU)
	g.ring(Vector2(0.62, 0.74), 0.16, 0.035, Color(g.color, 0.35), PI, TAU)


static func _letter(ci: CanvasItem, rect: Rect2, color: Color, text: String) -> void:
	if text.is_empty():
		return
	var font := ThemeDB.fallback_font
	var size := int(rect.size.y * 0.55)
	var letter := text.substr(0, 1).to_upper()
	var width := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := rect.position + Vector2((rect.size.x - width) * 0.5, rect.size.y * 0.5 + size * 0.35)
	ci.draw_string(font, baseline, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func _map(g: _Glyph, points: PackedVector2Array) -> PackedVector2Array:
	var mapped := PackedVector2Array()
	for point in points:
		mapped.append(g.p(point.x, point.y))
	return mapped
