@tool
class_name PixelArt
extends RefCounted

# Shared low-level drawing primitives for the game's procedural pixel art.
#
# Pure functions over an `Image` — no caching and no palette opinions. Each art
# module (`ChestArt`, `ItemFactory`, ...) owns its own colours and layout and
# just borrows the geometry helpers from here.
#
# All coordinates are inclusive and bounds-checked, so callers can describe a
# shape without clipping it by hand.


static func set_pixel(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or x >= image.get_width():
		return
	if y < 0 or y >= image.get_height():
		return
	image.set_pixel(x, y, color)


static func fill_rect(image: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			set_pixel(image, x, y, color)


static func horizontal_line(image: Image, x0: int, x1: int, y: int, color: Color) -> void:
	for x in range(x0, x1 + 1):
		set_pixel(image, x, y, color)


static func vertical_line(image: Image, y0: int, y1: int, x: int, color: Color) -> void:
	for y in range(y0, y1 + 1):
		set_pixel(image, x, y, color)


static func outline_silhouette(image: Image, outline: Color) -> void:
	# Wraps every opaque pixel in a 1px border. The filled pixels are collected
	# up front so the border we paint doesn't seed more border on the next step.
	# Callers must leave a 1px transparent margin around their art.
	var width := image.get_width()
	var height := image.get_height()
	var filled: Array[Vector2i] = []
	for y in height:
		for x in width:
			if image.get_pixel(x, y).a > 0.0:
				filled.append(Vector2i(x, y))

	const NEIGHBOURS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for point in filled:
		for offset in NEIGHBOURS:
			var neighbour: Vector2i = point + offset
			if neighbour.x < 0 or neighbour.x >= width:
				continue
			if neighbour.y < 0 or neighbour.y >= height:
				continue
			if image.get_pixel(neighbour.x, neighbour.y).a == 0.0:
				image.set_pixel(neighbour.x, neighbour.y, outline)
