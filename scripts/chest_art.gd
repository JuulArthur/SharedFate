@tool
class_name ChestArt
extends RefCounted

# Generates placeholder pixel-art textures for the treasure chest. The closed
# and open sprites share the same 32x32 footprint and the same body, so the
# swap on opening is pixel-aligned and only the lid appears to move.
#
# Textures are cached so dropping many chests into a level doesn't re-render
# the art per instance. Geometry helpers come from `PixelArt`.

const SIZE := Vector2i(32, 32)

static var _closed_texture: Texture2D
static var _open_texture: Texture2D


static func closed_texture() -> Texture2D:
	if _closed_texture == null:
		_closed_texture = _create_closed_texture()
	return _closed_texture


static func open_texture() -> Texture2D:
	if _open_texture == null:
		_open_texture = _create_open_texture()
	return _open_texture


# --- palette ---------------------------------------------------------------

static func _outline() -> Color:
	return Color(0.16, 0.10, 0.06)


static func _plank() -> Color:
	return Color(0.55, 0.36, 0.20)


static func _plank_shade() -> Color:
	return Color(0.40, 0.25, 0.13)


static func _plank_highlight() -> Color:
	return Color(0.70, 0.50, 0.30)


static func _metal() -> Color:
	return Color(0.36, 0.33, 0.30)


static func _metal_light() -> Color:
	return Color(0.58, 0.55, 0.50)


static func _gold() -> Color:
	return Color(0.87, 0.71, 0.26)


static func _gold_dark() -> Color:
	return Color(0.60, 0.47, 0.12)


static func _interior() -> Color:
	return Color(0.13, 0.09, 0.07)


# --- textures --------------------------------------------------------------

static func _create_closed_texture() -> Texture2D:
	var image := _new_image()

	_draw_body(image)
	_draw_lid_dome(image, 6)

	# Metal band along the seam where the lid meets the body.
	PixelArt.horizontal_line(image, 5, 26, 13, _metal())
	PixelArt.horizontal_line(image, 5, 26, 14, _metal_light())

	_draw_vertical_bands(image, 8, 27)
	_draw_lock(image, 15)

	PixelArt.outline_silhouette(image, _outline())
	return ImageTexture.create_from_image(image)


static func _create_open_texture() -> Texture2D:
	var image := _new_image()

	_draw_body(image)

	# Lid hinged back: the same dome, squashed and lifted clear of the opening.
	PixelArt.fill_rect(image, 6, 2, 25, 6, _plank_shade())
	PixelArt.horizontal_line(image, 8, 23, 2, _plank_highlight())
	PixelArt.horizontal_line(image, 6, 25, 6, _metal())

	# Dark mouth of the chest, with treasure catching the light inside.
	PixelArt.fill_rect(image, 5, 9, 26, 14, _interior())
	PixelArt.horizontal_line(image, 5, 26, 9, _outline())
	_draw_treasure(image)

	_draw_vertical_bands(image, 16, 27)

	PixelArt.outline_silhouette(image, _outline())
	return ImageTexture.create_from_image(image)


# --- shared pieces ---------------------------------------------------------

static func _new_image() -> Image:
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image


static func _draw_body(image: Image) -> void:
	# Three plank courses separated by dark seams, darkening toward the floor.
	PixelArt.fill_rect(image, 5, 15, 26, 27, _plank_shade())
	PixelArt.fill_rect(image, 5, 15, 26, 18, _plank())
	PixelArt.fill_rect(image, 5, 20, 26, 23, _plank())
	PixelArt.horizontal_line(image, 5, 26, 15, _plank_highlight())
	PixelArt.horizontal_line(image, 5, 26, 19, _outline())
	PixelArt.horizontal_line(image, 5, 26, 24, _outline())


static func _draw_lid_dome(image: Image, top_y: int) -> void:
	# Rounded lid: each row widens as it descends toward the body.
	var rows := [
		[top_y, 10, 21],
		[top_y + 1, 8, 23],
		[top_y + 2, 6, 25],
		[top_y + 3, 5, 26],
		[top_y + 4, 5, 26],
		[top_y + 5, 5, 26],
		[top_y + 6, 5, 26],
	]
	for row in rows:
		PixelArt.horizontal_line(image, int(row[1]), int(row[2]), int(row[0]), _plank())
	PixelArt.horizontal_line(image, 10, 21, top_y, _plank_highlight())
	PixelArt.horizontal_line(image, 5, 26, top_y + 6, _plank_shade())


static func _draw_vertical_bands(image: Image, y0: int, y1: int) -> void:
	for x in [9, 22]:
		PixelArt.vertical_line(image, y0, y1, x, _metal())
		PixelArt.vertical_line(image, y0, y1, x + 1, _metal_light())


static func _draw_lock(image: Image, top_y: int) -> void:
	PixelArt.fill_rect(image, 14, top_y - 4, 17, top_y + 2, _gold())
	PixelArt.horizontal_line(image, 14, 17, top_y + 2, _gold_dark())
	PixelArt.vertical_line(image, top_y - 4, top_y + 2, 17, _gold_dark())
	# Keyhole.
	PixelArt.fill_rect(image, 15, top_y - 1, 16, top_y, _outline())


static func _draw_treasure(image: Image) -> void:
	# Loose coins piled just below the rim so they read at a glance.
	for coin_x in [8, 12, 17, 21]:
		PixelArt.fill_rect(image, coin_x, 12, coin_x + 2, 13, _gold())
		PixelArt.horizontal_line(image, coin_x, coin_x + 2, 13, _gold_dark())
	PixelArt.fill_rect(image, 14, 10, 16, 11, _gold())
	PixelArt.horizontal_line(image, 14, 16, 11, _gold_dark())
	PixelArt.set_pixel(image, 10, 11, _gold())
	PixelArt.set_pixel(image, 20, 11, _gold())
