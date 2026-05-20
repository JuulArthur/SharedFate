class_name ItemFactory
extends RefCounted

# Static factory for building Item instances (including their procedural
# pixel art). Centralizing construction here keeps Player / Inventory free
# of art generation details and gives us one place to tune stats.

const SWORD_ICON_SIZE := Vector2i(12, 24)


static func create_sword() -> Item:
	var sword := Item.new()
	sword.id = &"iron_sword"
	sword.display_name = "Iron Sword"
	sword.description = "A simple iron sword. Reliable in close combat."
	sword.damage = 20
	sword.weapon_type = Item.WeaponType.MELEE
	# Match the player's current melee attack reach so behavior is unchanged
	# when the sword is equipped. See `Player.attack_range`.
	sword.weapon_range = 40.0
	sword.icon = _create_sword_texture()
	# Animation: shared one-handed sword swing. Sword hangs slightly below the
	# hand point with the blade tilted forward to read as "held".
	sword.animation_archetype = Item.ARCHETYPE_MELEE_SLASH
	sword.grip_offset = Vector2(0, -2)
	sword.grip_rotation_deg = -25.0
	return sword


static func _create_sword_texture() -> Texture2D:
	var image := Image.create(SWORD_ICON_SIZE.x, SWORD_ICON_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var outline := Color(0.08, 0.08, 0.12, 1.0)
	var blade_light := Color(0.88, 0.92, 0.96, 1.0)
	var blade_shadow := Color(0.58, 0.64, 0.74, 1.0)
	var crossguard_light := Color(0.90, 0.75, 0.30, 1.0)
	var crossguard_dark := Color(0.55, 0.42, 0.12, 1.0)
	var grip := Color(0.42, 0.27, 0.14, 1.0)
	var grip_shadow := Color(0.28, 0.17, 0.08, 1.0)
	var pommel_light := Color(0.95, 0.82, 0.35, 1.0)
	var pommel_dark := Color(0.62, 0.48, 0.15, 1.0)

	# Blade (y 0..15): tapered tip, then straight 2-pixel blade with highlight/shadow columns.
	image.set_pixel(5, 0, outline)
	image.set_pixel(6, 0, outline)
	for y in range(1, 16):
		image.set_pixel(4, y, outline)
		image.set_pixel(5, y, blade_light)
		image.set_pixel(6, y, blade_shadow)
		image.set_pixel(7, y, outline)

	# Crossguard (y 16..17): flared guard with a dark outline row.
	for x in range(2, 10):
		image.set_pixel(x, 16, outline)
	image.set_pixel(1, 17, outline)
	for x in range(2, 10):
		var color := crossguard_light if x % 2 == 0 else crossguard_dark
		image.set_pixel(x, 17, color)
	image.set_pixel(10, 17, outline)
	image.set_pixel(2, 18, outline)
	image.set_pixel(9, 18, outline)

	# Grip (y 18..21): 2px wide leather wrap.
	for y in range(18, 22):
		image.set_pixel(4, y, outline)
		image.set_pixel(5, y, grip)
		image.set_pixel(6, y, grip_shadow)
		image.set_pixel(7, y, outline)

	# Pommel (y 22..23): rounded cap.
	image.set_pixel(4, 22, outline)
	image.set_pixel(5, 22, pommel_light)
	image.set_pixel(6, 22, pommel_dark)
	image.set_pixel(7, 22, outline)
	image.set_pixel(5, 23, outline)
	image.set_pixel(6, 23, outline)

	return ImageTexture.create_from_image(image)
