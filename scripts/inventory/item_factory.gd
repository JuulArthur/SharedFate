class_name ItemFactory
extends RefCounted

# Static factory for building Item instances (including their procedural
# pixel art). Centralizing construction here keeps Player / Inventory free
# of art generation details and gives us one place to tune stats.

const SWORD_ICON_SIZE := Vector2i(12, 24)
const DAGGER_ICON_SIZE := Vector2i(8, 18)
const POTION_ICON_SIZE := Vector2i(12, 16)


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


static func create_dagger() -> Item:
	var dagger := Item.new()
	dagger.id = &"rusty_dagger"
	dagger.display_name = "Rusty Dagger"
	dagger.description = "Short and quick, but it barely holds an edge."
	dagger.damage = 12
	dagger.weapon_type = Item.WeaponType.MELEE
	dagger.weapon_range = 32.0
	dagger.icon = _create_dagger_texture()
	# Reuses the shared one-handed swing; only the grip fit differs from the
	# sword. See CODEBASE_GUIDE.md > "Weapon animations".
	dagger.animation_archetype = Item.ARCHETYPE_MELEE_SLASH
	dagger.grip_offset = Vector2(0, -1)
	dagger.grip_rotation_deg = -20.0
	return dagger


static func create_health_potion() -> Item:
	var potion := Item.new()
	potion.id = &"health_potion"
	potion.display_name = "Health Potion"
	potion.description = "Restores a modest amount of health."
	potion.weapon_type = Item.WeaponType.MELEE
	potion.icon = _create_potion_texture()
	potion.set_property(Item.PROPERTY_CATEGORY, Item.CATEGORY_CONSUMABLE)
	potion.set_property(&"heal_amount", 25)
	return potion


static func create_random_loot() -> Item:
	# Simple weighted table for enemies/chests that don't declare their own
	# loot. Keep the common consumable common and the weapon rarer.
	if randf() < 0.7:
		return create_health_potion()
	return create_dagger()


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


static func _create_dagger_texture() -> Texture2D:
	var image := Image.create(DAGGER_ICON_SIZE.x, DAGGER_ICON_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var blade_light := Color(0.74, 0.72, 0.66, 1.0)
	var blade_shadow := Color(0.50, 0.46, 0.40, 1.0)
	var rust := Color(0.55, 0.32, 0.18, 1.0)
	var guard_light := Color(0.58, 0.52, 0.34, 1.0)
	var guard_dark := Color(0.38, 0.33, 0.20, 1.0)
	var grip := Color(0.36, 0.23, 0.12, 1.0)
	var grip_shadow := Color(0.24, 0.15, 0.07, 1.0)

	# Blade (y 1..10): tapered tip then a 2px blade with a highlight column.
	PixelArt.horizontal_line(image, 3, 4, 1, blade_light)
	for y in range(2, 11):
		image.set_pixel(3, y, blade_light)
		image.set_pixel(4, y, blade_shadow)
	# A few rust specks so it reads as "rusty" at icon size.
	image.set_pixel(4, 4, rust)
	image.set_pixel(3, 8, rust)

	# Crossguard, grip and pommel.
	PixelArt.horizontal_line(image, 1, 6, 11, guard_dark)
	image.set_pixel(2, 11, guard_light)
	image.set_pixel(5, 11, guard_light)
	for y in range(12, 16):
		image.set_pixel(3, y, grip)
		image.set_pixel(4, y, grip_shadow)
	PixelArt.horizontal_line(image, 3, 4, 16, guard_light)

	PixelArt.outline_silhouette(image, Color(0.08, 0.08, 0.12, 1.0))
	return ImageTexture.create_from_image(image)


static func _create_potion_texture() -> Texture2D:
	var image := Image.create(POTION_ICON_SIZE.x, POTION_ICON_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var cork := Color(0.45, 0.30, 0.16, 1.0)
	var cork_dark := Color(0.31, 0.20, 0.10, 1.0)
	var glass := Color(0.62, 0.78, 0.82, 1.0)
	var glass_shine := Color(0.90, 0.97, 0.99, 1.0)
	var liquid := Color(0.80, 0.19, 0.26, 1.0)
	var liquid_dark := Color(0.58, 0.11, 0.18, 1.0)

	# Round flask silhouette, row by row: [y, x_start, x_end].
	var body_rows := [
		[5, 4, 7], [6, 3, 8],
		[7, 2, 9], [8, 2, 9], [9, 2, 9], [10, 2, 9], [11, 2, 9], [12, 2, 9],
		[13, 3, 8], [14, 4, 7],
	]

	# Cork and neck.
	PixelArt.horizontal_line(image, 5, 6, 1, cork)
	PixelArt.horizontal_line(image, 4, 7, 2, cork_dark)
	PixelArt.horizontal_line(image, 5, 6, 3, glass)
	PixelArt.horizontal_line(image, 5, 6, 4, glass)

	# Empty glass first, then fill the lower half with liquid.
	for row in body_rows:
		PixelArt.horizontal_line(image, int(row[1]), int(row[2]), int(row[0]), glass)
	for row in body_rows:
		var y := int(row[0])
		if y < 9:
			continue
		PixelArt.horizontal_line(image, int(row[1]), int(row[2]), y, liquid if y < 13 else liquid_dark)

	# Shine along the upper-left curve of the glass.
	image.set_pixel(3, 7, glass_shine)
	image.set_pixel(3, 8, glass_shine)

	PixelArt.outline_silhouette(image, Color(0.08, 0.08, 0.12, 1.0))
	return ImageTexture.create_from_image(image)
