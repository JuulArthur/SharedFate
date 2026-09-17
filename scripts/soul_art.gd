class_name SoulArt
extends RefCounted

# Procedural pixel art for the three souls: placeholder bodies for the rogue
# and the mage (the knight has real art under assets/player/) and a small
# portrait for each, used by the HUD.
#
# Bodies are drawn on the same 68x68 canvas as the knight sprites with the
# figure in the same footprint (x 21..46, y 11..57), so the health bar, hand
# point and collision line up no matter who is in control. Replace these with
# authored sprites by swapping the SpriteFrames in `Player._setup_body_visuals`.

const BODY_CANVAS := Vector2i(68, 68)
const PORTRAIT_SIZE := Vector2i(16, 16)

const OUTLINE := Color(0.07, 0.06, 0.08, 1.0)

# Rogue palette.
const ROGUE_HOOD := Color(0.20, 0.30, 0.22, 1.0)
const ROGUE_HOOD_LIGHT := Color(0.27, 0.40, 0.29, 1.0)
const ROGUE_CLOAK := Color(0.16, 0.19, 0.17, 1.0)
const ROGUE_CLOAK_DARK := Color(0.10, 0.12, 0.11, 1.0)
const ROGUE_FACE_SHADOW := Color(0.14, 0.11, 0.12, 1.0)
const ROGUE_SKIN := Color(0.62, 0.50, 0.42, 1.0)
const ROGUE_EYE := Color(0.80, 1.0, 0.82, 1.0)
const ROGUE_SCARF := Color(0.55, 0.16, 0.16, 1.0)
const ROGUE_BELT := Color(0.34, 0.22, 0.12, 1.0)
const ROGUE_BUCKLE := Color(0.72, 0.62, 0.34, 1.0)
const ROGUE_TROUSERS := Color(0.19, 0.19, 0.21, 1.0)
const ROGUE_BOOT := Color(0.11, 0.09, 0.08, 1.0)

# Mage palette.
const MAGE_ROBE := Color(0.36, 0.22, 0.55, 1.0)
const MAGE_ROBE_DARK := Color(0.24, 0.14, 0.38, 1.0)
const MAGE_ROBE_TRIM := Color(0.62, 0.48, 0.82, 1.0)
const MAGE_HAT := Color(0.30, 0.18, 0.48, 1.0)
const MAGE_HAT_LIGHT := Color(0.40, 0.26, 0.60, 1.0)
const MAGE_BAND := Color(0.85, 0.70, 0.32, 1.0)
const MAGE_SKIN := Color(0.86, 0.76, 0.68, 1.0)
const MAGE_EYE := Color(0.18, 0.12, 0.22, 1.0)
const MAGE_HAIR := Color(0.78, 0.78, 0.82, 1.0)
const MAGE_STAR := Color(1.0, 0.92, 0.55, 1.0)

# Knight portrait palette.
const KNIGHT_STEEL := Color(0.70, 0.74, 0.80, 1.0)
const KNIGHT_STEEL_LIGHT := Color(0.86, 0.89, 0.94, 1.0)
const KNIGHT_STEEL_DARK := Color(0.46, 0.50, 0.58, 1.0)
const KNIGHT_VISOR := Color(0.08, 0.08, 0.12, 1.0)
const KNIGHT_PLUME := Color(0.30, 0.48, 0.90, 1.0)


# --- Bodies -------------------------------------------------------------------

static func create_rogue_body() -> Texture2D:
	var image := _new_body_image()

	# Hood: a rounded dome that drapes out onto the shoulders.
	PixelArt.horizontal_line(image, 30, 37, 11, ROGUE_HOOD_LIGHT)
	PixelArt.horizontal_line(image, 28, 39, 12, ROGUE_HOOD_LIGHT)
	PixelArt.fill_rect(image, 26, 13, 41, 25, ROGUE_HOOD)
	PixelArt.vertical_line(image, 13, 25, 26, ROGUE_HOOD_LIGHT)
	PixelArt.fill_rect(image, 24, 26, 43, 29, ROGUE_HOOD)
	PixelArt.horizontal_line(image, 24, 43, 29, ROGUE_CLOAK_DARK)

	# The face sits back in shadow; only the lower half catches light.
	PixelArt.fill_rect(image, 29, 17, 38, 25, ROGUE_FACE_SHADOW)
	PixelArt.fill_rect(image, 30, 21, 37, 25, ROGUE_SKIN)
	PixelArt.set_pixel(image, 31, 20, ROGUE_EYE)
	PixelArt.set_pixel(image, 36, 20, ROGUE_EYE)

	# Scarf across the throat.
	PixelArt.fill_rect(image, 29, 26, 38, 27, ROGUE_SCARF)

	# Cloak body with a centre seam, arms held close.
	PixelArt.fill_rect(image, 26, 30, 41, 46, ROGUE_CLOAK)
	PixelArt.vertical_line(image, 30, 46, 33, ROGUE_CLOAK_DARK)
	PixelArt.vertical_line(image, 30, 46, 34, ROGUE_CLOAK_DARK)
	PixelArt.fill_rect(image, 22, 30, 25, 42, ROGUE_CLOAK_DARK)
	PixelArt.fill_rect(image, 42, 30, 45, 42, ROGUE_CLOAK_DARK)
	PixelArt.fill_rect(image, 22, 43, 25, 45, ROGUE_SKIN)
	PixelArt.fill_rect(image, 42, 43, 45, 45, ROGUE_SKIN)

	# Belt and buckle.
	PixelArt.fill_rect(image, 26, 40, 41, 41, ROGUE_BELT)
	PixelArt.fill_rect(image, 33, 40, 34, 41, ROGUE_BUCKLE)

	# Legs and boots.
	PixelArt.fill_rect(image, 27, 47, 32, 53, ROGUE_TROUSERS)
	PixelArt.fill_rect(image, 35, 47, 40, 53, ROGUE_TROUSERS)
	PixelArt.fill_rect(image, 26, 54, 32, 57, ROGUE_BOOT)
	PixelArt.fill_rect(image, 35, 54, 41, 57, ROGUE_BOOT)

	PixelArt.outline_silhouette(image, OUTLINE)
	return ImageTexture.create_from_image(image)


static func create_mage_body() -> Texture2D:
	var image := _new_body_image()

	# Pointed hat: widens one pixel a side every two rows down to the band.
	for row in range(8, 19):
		var half := int((row - 8) / 2) + 1
		PixelArt.horizontal_line(image, 34 - half, 35 + half, row, MAGE_HAT)
		PixelArt.set_pixel(image, 34 - half, row, MAGE_HAT_LIGHT)
	PixelArt.set_pixel(image, 36, 12, MAGE_STAR)
	PixelArt.fill_rect(image, 28, 19, 41, 20, MAGE_BAND)
	PixelArt.fill_rect(image, 23, 21, 46, 22, MAGE_HAT)
	PixelArt.horizontal_line(image, 23, 46, 21, MAGE_HAT_LIGHT)

	# Face framed by long grey hair.
	PixelArt.fill_rect(image, 29, 23, 38, 29, MAGE_SKIN)
	PixelArt.vertical_line(image, 23, 28, 28, MAGE_HAIR)
	PixelArt.vertical_line(image, 23, 28, 39, MAGE_HAIR)
	PixelArt.set_pixel(image, 31, 25, MAGE_EYE)
	PixelArt.set_pixel(image, 36, 25, MAGE_EYE)

	# Robe: a trapezoid that flares to the hem, with a lighter centre trim.
	for row in range(30, 58):
		var flare := int((row - 30) / 5)
		PixelArt.horizontal_line(image, 28 - flare, 39 + flare, row, MAGE_ROBE)
		PixelArt.set_pixel(image, 28 - flare, row, MAGE_ROBE_DARK)
		PixelArt.set_pixel(image, 39 + flare, row, MAGE_ROBE_DARK)
	PixelArt.fill_rect(image, 33, 30, 34, 57, MAGE_ROBE_TRIM)
	PixelArt.fill_rect(image, 25, 40, 42, 41, MAGE_BAND)

	# Sleeves and hands.
	PixelArt.fill_rect(image, 24, 31, 27, 42, MAGE_ROBE_DARK)
	PixelArt.fill_rect(image, 40, 31, 43, 42, MAGE_ROBE_DARK)
	PixelArt.fill_rect(image, 24, 43, 27, 44, MAGE_SKIN)
	PixelArt.fill_rect(image, 40, 43, 43, 44, MAGE_SKIN)

	PixelArt.outline_silhouette(image, OUTLINE)
	return ImageTexture.create_from_image(image)


# --- Portraits ----------------------------------------------------------------

static func create_portrait(kind: Soul.Kind) -> Texture2D:
	match kind:
		Soul.Kind.KNIGHT: return _create_knight_portrait()
		Soul.Kind.ROGUE: return _create_rogue_portrait()
		Soul.Kind.MAGE: return _create_mage_portrait()
	return _create_knight_portrait()


static func _create_knight_portrait() -> Texture2D:
	var image := _new_portrait_image()
	# Plume, dome, visor slit, chin guard.
	PixelArt.fill_rect(image, 7, 0, 8, 2, KNIGHT_PLUME)
	PixelArt.horizontal_line(image, 5, 10, 2, KNIGHT_STEEL_LIGHT)
	PixelArt.fill_rect(image, 4, 3, 11, 12, KNIGHT_STEEL)
	PixelArt.vertical_line(image, 3, 12, 4, KNIGHT_STEEL_LIGHT)
	PixelArt.vertical_line(image, 3, 12, 11, KNIGHT_STEEL_DARK)
	PixelArt.fill_rect(image, 5, 7, 10, 8, KNIGHT_VISOR)
	PixelArt.vertical_line(image, 6, 10, 7, KNIGHT_STEEL_DARK)
	PixelArt.vertical_line(image, 6, 10, 8, KNIGHT_STEEL_DARK)
	PixelArt.horizontal_line(image, 5, 10, 13, KNIGHT_STEEL_DARK)
	PixelArt.outline_silhouette(image, OUTLINE)
	return ImageTexture.create_from_image(image)


static func _create_rogue_portrait() -> Texture2D:
	var image := _new_portrait_image()
	# Hood with the face sunk into shadow, two glinting eyes, red scarf.
	PixelArt.horizontal_line(image, 6, 9, 1, ROGUE_HOOD_LIGHT)
	PixelArt.fill_rect(image, 3, 2, 12, 13, ROGUE_HOOD)
	PixelArt.vertical_line(image, 2, 13, 3, ROGUE_HOOD_LIGHT)
	PixelArt.fill_rect(image, 5, 6, 10, 12, ROGUE_FACE_SHADOW)
	PixelArt.fill_rect(image, 6, 10, 9, 12, ROGUE_SKIN)
	PixelArt.set_pixel(image, 6, 8, ROGUE_EYE)
	PixelArt.set_pixel(image, 9, 8, ROGUE_EYE)
	PixelArt.fill_rect(image, 4, 13, 11, 14, ROGUE_SCARF)
	PixelArt.outline_silhouette(image, OUTLINE)
	return ImageTexture.create_from_image(image)


static func _create_mage_portrait() -> Texture2D:
	var image := _new_portrait_image()
	# Pointed hat with a star, gold band and wide brim over a pale face.
	for row in range(1, 8):
		var half := int((row - 1) / 2) + 1
		PixelArt.horizontal_line(image, 7 - half, 8 + half, row, MAGE_HAT)
	PixelArt.set_pixel(image, 8, 4, MAGE_STAR)
	PixelArt.horizontal_line(image, 4, 11, 8, MAGE_BAND)
	PixelArt.horizontal_line(image, 2, 13, 9, MAGE_HAT_LIGHT)
	PixelArt.fill_rect(image, 5, 10, 10, 14, MAGE_SKIN)
	PixelArt.vertical_line(image, 10, 13, 4, MAGE_HAIR)
	PixelArt.vertical_line(image, 10, 13, 11, MAGE_HAIR)
	PixelArt.set_pixel(image, 6, 11, MAGE_EYE)
	PixelArt.set_pixel(image, 9, 11, MAGE_EYE)
	PixelArt.outline_silhouette(image, OUTLINE)
	return ImageTexture.create_from_image(image)


# --- Helpers ------------------------------------------------------------------

static func _new_body_image() -> Image:
	var image := Image.create(BODY_CANVAS.x, BODY_CANVAS.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image


static func _new_portrait_image() -> Image:
	var image := Image.create(PORTRAIT_SIZE.x, PORTRAIT_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image
