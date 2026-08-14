@tool
class_name CrateArt
extends RefCounted

# Generates placeholder pixel-art textures for the breakable crate. Both the
# intact and broken sprites share the same 32x32 footprint so the swap is
# pixel-aligned. Textures are cached so dropping many crates in the editor
# doesn't allocate per-instance.

const SIZE := Vector2i(32, 32)

static var _intact_texture: Texture2D
static var _broken_texture: Texture2D
static var _splinter_texture: Texture2D


static func intact_texture() -> Texture2D:
	if _intact_texture == null:
		_intact_texture = _create_intact_texture()
	return _intact_texture


static func broken_texture() -> Texture2D:
	if _broken_texture == null:
		_broken_texture = _create_broken_texture()
	return _broken_texture


static func splinter_texture() -> Texture2D:
	if _splinter_texture == null:
		_splinter_texture = _create_splinter_texture()
	return _splinter_texture


static func _palette_outline() -> Color:
	return Color(0.16, 0.10, 0.06)


static func _palette_plank() -> Color:
	return Color(0.55, 0.36, 0.20)


static func _palette_plank_shade() -> Color:
	return Color(0.40, 0.25, 0.13)


static func _palette_plank_highlight() -> Color:
	return Color(0.70, 0.50, 0.30)


static func _palette_metal() -> Color:
	return Color(0.30, 0.30, 0.34)


static func _palette_nail() -> Color:
	return Color(0.78, 0.78, 0.82)


static func _create_intact_texture() -> Texture2D:
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var outline := _palette_outline()
	var plank := _palette_plank()
	var plank_shade := _palette_plank_shade()
	var plank_highlight := _palette_plank_highlight()
	var metal := _palette_metal()
	var nail := _palette_nail()

	_fill_rect(image, 2, 2, 29, 29, outline)
	_fill_rect(image, 3, 3, 28, 28, plank_shade)
	_fill_rect(image, 3, 3, 28, 5, plank)
	_fill_rect(image, 3, 11, 28, 13, plank)
	_fill_rect(image, 3, 19, 28, 21, plank)
	_fill_rect(image, 3, 27, 28, 28, plank_shade)

	_horizontal_line(image, 3, 28, 9, outline)
	_horizontal_line(image, 3, 28, 17, outline)
	_horizontal_line(image, 3, 28, 25, outline)

	for y_top in [3, 11, 19]:
		_horizontal_line(image, 3, 28, y_top, plank_highlight)

	for x in [3, 30]:
		_vertical_line(image, 3, 28, x, plank_shade)
	_vertical_line(image, 2, 29, 2, outline)
	_vertical_line(image, 2, 29, 29, outline)

	_vertical_line(image, 3, 28, 16, plank_shade)

	for x in [5, 27]:
		for y in [3, 11, 19, 27]:
			image.set_pixel(x, y, nail)

	_fill_rect(image, 14, 7, 18, 9, metal)
	_fill_rect(image, 14, 23, 18, 25, metal)
	image.set_pixel(15, 8, nail)
	image.set_pixel(16, 24, nail)

	return ImageTexture.create_from_image(image)


static func _create_broken_texture() -> Texture2D:
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var outline := _palette_outline()
	var plank := _palette_plank()
	var plank_shade := _palette_plank_shade()
	var plank_highlight := _palette_plank_highlight()
	var nail := _palette_nail()

	_fill_rect(image, 4, 18, 27, 28, plank_shade)
	_fill_rect(image, 4, 18, 27, 19, plank)
	_horizontal_line(image, 4, 27, 18, plank_highlight)
	_horizontal_line(image, 4, 27, 25, outline)
	_horizontal_line(image, 4, 27, 28, outline)
	_vertical_line(image, 18, 29, 3, outline)
	_vertical_line(image, 18, 29, 28, outline)

	_draw_diagonal_crack(image, 6, 24, 12, 18, outline)
	_draw_diagonal_crack(image, 18, 18, 24, 24, outline)
	image.set_pixel(10, 21, plank_shade)
	image.set_pixel(20, 23, plank_shade)

	image.set_pixel(7, 16, plank)
	image.set_pixel(8, 16, plank_shade)
	image.set_pixel(8, 17, outline)
	image.set_pixel(7, 17, outline)
	image.set_pixel(6, 17, outline)

	image.set_pixel(14, 14, plank)
	image.set_pixel(15, 14, plank_shade)
	image.set_pixel(14, 15, outline)
	image.set_pixel(15, 15, outline)
	image.set_pixel(13, 15, outline)
	image.set_pixel(16, 15, outline)

	image.set_pixel(22, 15, plank)
	image.set_pixel(23, 15, plank_shade)
	image.set_pixel(22, 16, outline)
	image.set_pixel(23, 16, outline)
	image.set_pixel(21, 16, outline)
	image.set_pixel(24, 16, outline)

	for x in [6, 26]:
		image.set_pixel(x, 26, nail)

	_draw_splinter(image, 2, 16, plank_shade, outline)
	_draw_splinter(image, 28, 17, plank_shade, outline)

	return ImageTexture.create_from_image(image)


static func _create_splinter_texture() -> Texture2D:
	var image := Image.create(6, 6, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var outline := _palette_outline()
	var plank := _palette_plank()
	var plank_shade := _palette_plank_shade()
	image.set_pixel(2, 1, outline)
	image.set_pixel(2, 2, plank)
	image.set_pixel(3, 2, plank_shade)
	image.set_pixel(2, 3, plank)
	image.set_pixel(3, 3, plank_shade)
	image.set_pixel(2, 4, outline)
	image.set_pixel(3, 4, outline)
	image.set_pixel(1, 3, outline)
	return ImageTexture.create_from_image(image)


# --- low-level draw helpers -----------------------------------------------

static func _fill_rect(image: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x >= 0 and x < image.get_width() and y >= 0 and y < image.get_height():
				image.set_pixel(x, y, color)


static func _horizontal_line(image: Image, x0: int, x1: int, y: int, color: Color) -> void:
	for x in range(x0, x1 + 1):
		image.set_pixel(x, y, color)


static func _vertical_line(image: Image, y0: int, y1: int, x: int, color: Color) -> void:
	for y in range(y0, y1 + 1):
		image.set_pixel(x, y, color)


static func _draw_diagonal_crack(image: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	var dx: int = x1 - x0
	var dy: int = y1 - y0
	var steps: int = maxi(absi(dx), absi(dy))
	if steps == 0:
		return
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var x := int(round(lerpf(float(x0), float(x1), t)))
		var y := int(round(lerpf(float(y0), float(y1), t)))
		image.set_pixel(x, y, color)


static func _draw_splinter(image: Image, x: int, y: int, plank: Color, outline: Color) -> void:
	if x < 0 or x >= image.get_width():
		return
	image.set_pixel(x, y, outline)
	if y + 1 < image.get_height():
		image.set_pixel(x, y + 1, plank)
	if y + 2 < image.get_height():
		image.set_pixel(x, y + 2, outline)
