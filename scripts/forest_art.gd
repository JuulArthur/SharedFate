@tool
class_name ForestArt
extends RefCounted

# Small helper that generates the placeholder pixel-art used by the forest
# tree and tent scenes. The textures are cached per-class so dropping many
# trees in the editor reuses the same image.

static var _tree_texture: Texture2D
static var _tent_texture: Texture2D


static func tree_texture() -> Texture2D:
	if _tree_texture == null:
		_tree_texture = _create_tree_texture()
	return _tree_texture


static func tent_texture() -> Texture2D:
	if _tent_texture == null:
		_tent_texture = _create_tent_texture()
	return _tent_texture


static func _create_tree_texture() -> Texture2D:
	var image := Image.create(40, 60, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var trunk_color := Color(0.30, 0.20, 0.12)
	var trunk_shade := Color(0.20, 0.13, 0.08)
	for y in range(40, 56):
		for x in range(17, 23):
			var color := trunk_color
			if x <= 18:
				color = trunk_shade
			image.set_pixel(x, y, color)

	var center := Vector2(20, 24)
	var canopy_outer := Color(0.10, 0.27, 0.14)
	var canopy_mid := Color(0.13, 0.34, 0.18)
	var canopy_inner := Color(0.18, 0.44, 0.24)
	for y in range(60):
		for x in range(40):
			var dx := float(x) - center.x
			var dy := (float(y) - center.y) * 1.15
			var d := sqrt(dx * dx + dy * dy)
			if d <= 9.0:
				image.set_pixel(x, y, canopy_inner)
			elif d <= 14.0:
				image.set_pixel(x, y, canopy_mid)
			elif d <= 18.0:
				image.set_pixel(x, y, canopy_outer)

	return ImageTexture.create_from_image(image)


static func _create_tent_texture() -> Texture2D:
	var image := Image.create(56, 40, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var fabric_main := Color(0.62, 0.46, 0.25)
	var fabric_shade := Color(0.40, 0.28, 0.16)
	var pole_color := Color(0.30, 0.20, 0.12)
	var door_color := Color(0.16, 0.09, 0.05)

	for y in range(6, 40):
		var row_t := float(y - 6) / 33.0
		var width := int(round(lerpf(2.0, 24.0, row_t)))
		for x in range(28 - width, 28 + width):
			var color := fabric_main
			if x < 28:
				color = fabric_shade
			image.set_pixel(x, y, color)

	for y in range(22, 38):
		for x in range(26, 30):
			image.set_pixel(x, y, door_color)

	for y in range(0, 8):
		image.set_pixel(28, y, pole_color)

	return ImageTexture.create_from_image(image)
