class_name ItemFactory
extends RefCounted

# Static factory for building Item instances (including their procedural
# pixel art). Centralizing construction here keeps Player / Inventory free
# of art generation details and gives us one place to tune stats.

const SWORD_ICON_SIZE := Vector2i(12, 24)
const DAGGER_ICON_SIZE := Vector2i(8, 18)
const POTION_ICON_SIZE := Vector2i(12, 16)
const GEAR_ICON_SIZE := Vector2i(16, 16)




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


# --- Wearables -------------------------------------------------------------
#
# Each one declares the slot it occupies and how much armour it adds, both via
# `Item.properties`, so adding gear never means touching the `Item` class.

static func create_helmet() -> Item:
	var item := _make_gear(&"iron_helm", "Iron Helm", "Dented, but it has kept a skull intact before.",
		Item.SLOT_HEAD, 4)
	item.icon = _create_helmet_texture()
	return item


static func create_chestplate() -> Item:
	var item := _make_gear(&"iron_cuirass", "Iron Cuirass", "Heavy plate over a padded jerkin.",
		Item.SLOT_CHEST, 8)
	item.icon = _create_chestplate_texture()
	return item


static func create_shield() -> Item:
	var item := _make_gear(&"oak_shield", "Oak Shield", "Banded oak. Splinters before you do.",
		Item.SLOT_OFF_HAND, 5)
	item.icon = _create_shield_texture()
	return item


static func create_boots() -> Item:
	var item := _make_gear(&"leather_boots", "Leather Boots", "Worn soft by long roads.",
		Item.SLOT_FEET, 2)
	item.icon = _create_boots_texture()
	return item


static func create_greaves() -> Item:
	var item := _make_gear(&"iron_greaves", "Iron Greaves", "Shin plates that clatter when you run.",
		Item.SLOT_LEGS, 3)
	item.icon = _create_greaves_texture()
	return item


static func create_cloak() -> Item:
	var item := _make_gear(&"red_cloak", "Red Cloak", "Travel-stained, and still the finest thing you own.",
		Item.SLOT_BACK, 1)
	item.icon = _create_cloak_texture()
	return item


static func create_amulet() -> Item:
	var item := _make_gear(&"amber_amulet", "Amber Amulet", "The stone is warm to the touch.",
		Item.SLOT_NECK, 1, Item.CATEGORY_ACCESSORY)
	item.icon = _create_amulet_texture()
	return item


static func create_ring() -> Item:
	var item := _make_gear(&"silver_ring", "Silver Ring", "A plain band with a blue stone.",
		Item.SLOT_RING_LEFT, 1, Item.CATEGORY_ACCESSORY)
	item.icon = _create_ring_texture()
	return item


# Every wearable this factory builds, so callers (the loot table, debug spawns,
# tests) can walk the whole set without naming each one.
static func gear_builders() -> Array[Callable]:
	return [
		create_helmet, create_chestplate, create_shield, create_boots,
		create_greaves, create_cloak, create_amulet, create_ring,
	]


static func create_random_gear() -> Item:
	var builders := gear_builders()
	return builders[randi() % builders.size()].call()


static func _make_gear(id: StringName, display_name: String, description: String,
		slot: StringName, armor: int, category: StringName = Item.CATEGORY_ARMOR) -> Item:
	var item := Item.new()
	item.id = id
	item.display_name = display_name
	item.description = description
	item.set_property(Item.PROPERTY_CATEGORY, category)
	item.set_property(Item.PROPERTY_EQUIP_SLOT, slot)
	item.set_property(Item.PROPERTY_ARMOR, armor)
	return item


static func create_random_loot() -> Item:
	# Simple weighted table for enemies/chests that don't declare their own
	# loot. Keep the common consumable common and real gear rarer.
	var roll := randf()
	if roll < 0.5:
		return create_health_potion()
	if roll < 0.7:
		return create_dagger()
	return create_random_gear()


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


# --- Wearable art ----------------------------------------------------------
#
# All eight share one 16x16 canvas and the same recipe: block in the silhouette
# with a light and a shadow tone, add one highlight, then let
# `PixelArt.outline_silhouette` draw the border. Leave a 1px transparent margin
# so the outline has somewhere to go.

static func _new_gear_image() -> Image:
	var image := Image.create(GEAR_ICON_SIZE.x, GEAR_ICON_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image


static func _finish_gear(image: Image) -> Texture2D:
	PixelArt.outline_silhouette(image, Color(0.08, 0.08, 0.12, 1.0))
	return ImageTexture.create_from_image(image)


static func _create_helmet_texture() -> Texture2D:
	var image := _new_gear_image()
	var steel := Color(0.62, 0.66, 0.72, 1.0)
	var steel_dark := Color(0.40, 0.44, 0.50, 1.0)
	var shine := Color(0.86, 0.90, 0.95, 1.0)
	var visor := Color(0.16, 0.17, 0.21, 1.0)

	# Domed skull, then the face plate with a vision slit.
	PixelArt.fill_rect(image, 5, 2, 10, 3, steel)
	PixelArt.fill_rect(image, 4, 4, 11, 11, steel)
	PixelArt.fill_rect(image, 4, 12, 11, 13, steel_dark)
	# Right half in shadow.
	PixelArt.fill_rect(image, 9, 4, 11, 11, steel_dark)
	PixelArt.vertical_line(image, 3, 10, 5, shine)
	# Vision slit and nose guard.
	PixelArt.fill_rect(image, 5, 7, 10, 8, visor)
	PixelArt.vertical_line(image, 6, 11, 7, visor)
	PixelArt.vertical_line(image, 6, 11, 8, visor)
	return _finish_gear(image)


static func _create_chestplate_texture() -> Texture2D:
	var image := _new_gear_image()
	var steel := Color(0.60, 0.64, 0.71, 1.0)
	var steel_dark := Color(0.38, 0.42, 0.49, 1.0)
	var shine := Color(0.85, 0.89, 0.94, 1.0)
	var strap := Color(0.66, 0.20, 0.18, 1.0)

	# Pauldrons, then the torso tapering to the waist.
	PixelArt.fill_rect(image, 2, 3, 4, 5, steel_dark)
	PixelArt.fill_rect(image, 11, 3, 13, 5, steel_dark)
	PixelArt.fill_rect(image, 5, 2, 10, 12, steel)
	PixelArt.fill_rect(image, 9, 2, 10, 12, steel_dark)
	PixelArt.fill_rect(image, 6, 13, 9, 13, steel_dark)
	PixelArt.vertical_line(image, 3, 11, 6, shine)
	# Belted waist.
	PixelArt.horizontal_line(image, 5, 10, 11, strap)
	return _finish_gear(image)


static func _create_shield_texture() -> Texture2D:
	var image := _new_gear_image()
	var wood := Color(0.55, 0.38, 0.21, 1.0)
	var wood_dark := Color(0.38, 0.25, 0.13, 1.0)
	var band := Color(0.52, 0.55, 0.60, 1.0)
	var boss := Color(0.74, 0.77, 0.82, 1.0)

	# Heater shape: square shoulders narrowing to a point.
	PixelArt.fill_rect(image, 3, 2, 12, 9, wood)
	PixelArt.fill_rect(image, 9, 2, 12, 9, wood_dark)
	PixelArt.fill_rect(image, 4, 10, 11, 11, wood)
	PixelArt.fill_rect(image, 5, 12, 10, 12, wood_dark)
	PixelArt.fill_rect(image, 7, 13, 8, 13, wood_dark)
	# Iron banding and centre boss.
	PixelArt.horizontal_line(image, 3, 12, 5, band)
	PixelArt.fill_rect(image, 7, 6, 8, 7, boss)
	return _finish_gear(image)


static func _create_boots_texture() -> Texture2D:
	var image := _new_gear_image()
	var leather := Color(0.52, 0.34, 0.18, 1.0)
	var leather_dark := Color(0.34, 0.21, 0.10, 1.0)
	var sole := Color(0.22, 0.17, 0.13, 1.0)
	var cuff := Color(0.66, 0.46, 0.26, 1.0)

	# A pair, side by side: shaft, then the foot turning forward.
	for x0 in [3, 9]:
		PixelArt.fill_rect(image, x0, 3, x0 + 2, 3, cuff)
		PixelArt.fill_rect(image, x0, 4, x0 + 2, 10, leather)
		PixelArt.vertical_line(image, 4, 10, x0 + 2, leather_dark)
		PixelArt.fill_rect(image, x0, 11, x0 + 3, 12, leather)
		PixelArt.fill_rect(image, x0, 13, x0 + 3, 13, sole)
	return _finish_gear(image)


static func _create_greaves_texture() -> Texture2D:
	var image := _new_gear_image()
	var steel := Color(0.62, 0.66, 0.72, 1.0)
	var steel_dark := Color(0.40, 0.44, 0.50, 1.0)
	var shine := Color(0.86, 0.90, 0.95, 1.0)

	# Two shin plates, each flared at the knee.
	for x0 in [3, 9]:
		PixelArt.fill_rect(image, x0, 2, x0 + 3, 3, steel_dark)
		PixelArt.fill_rect(image, x0, 4, x0 + 3, 12, steel)
		PixelArt.vertical_line(image, 4, 12, x0 + 3, steel_dark)
		PixelArt.vertical_line(image, 5, 11, x0, shine)
		PixelArt.fill_rect(image, x0, 13, x0 + 3, 13, steel_dark)
	return _finish_gear(image)


static func _create_cloak_texture() -> Texture2D:
	var image := _new_gear_image()
	var cloth := Color(0.70, 0.18, 0.18, 1.0)
	var cloth_dark := Color(0.48, 0.10, 0.12, 1.0)
	var cloth_light := Color(0.85, 0.30, 0.26, 1.0)
	var clasp := Color(0.86, 0.72, 0.30, 1.0)

	# Collar, then cloth widening as it falls.
	PixelArt.fill_rect(image, 5, 2, 10, 3, cloth_dark)
	PixelArt.fill_rect(image, 4, 4, 11, 8, cloth)
	PixelArt.fill_rect(image, 3, 9, 12, 13, cloth)
	# Folds: a lit edge and two shadowed creases.
	PixelArt.vertical_line(image, 4, 13, 5, cloth_light)
	PixelArt.vertical_line(image, 5, 13, 8, cloth_dark)
	PixelArt.vertical_line(image, 9, 13, 11, cloth_dark)
	PixelArt.fill_rect(image, 7, 2, 8, 2, clasp)
	return _finish_gear(image)


static func _create_amulet_texture() -> Texture2D:
	var image := _new_gear_image()
	var chain := Color(0.72, 0.74, 0.78, 1.0)
	var chain_dark := Color(0.48, 0.50, 0.55, 1.0)
	var stone := Color(0.92, 0.62, 0.16, 1.0)
	var stone_dark := Color(0.68, 0.38, 0.08, 1.0)
	var glint := Color(1.0, 0.85, 0.50, 1.0)

	# Chain: two strands meeting at the bail.
	for i in 5:
		PixelArt.set_pixel(image, 4 - int(i / 3), 2 + i, chain if i % 2 == 0 else chain_dark)
		PixelArt.set_pixel(image, 11 + int(i / 3), 2 + i, chain if i % 2 == 0 else chain_dark)
	PixelArt.horizontal_line(image, 5, 10, 7, chain_dark)
	# Amber drop.
	PixelArt.fill_rect(image, 6, 8, 9, 11, stone)
	PixelArt.fill_rect(image, 8, 9, 9, 11, stone_dark)
	PixelArt.fill_rect(image, 7, 12, 8, 12, stone_dark)
	PixelArt.set_pixel(image, 6, 8, glint)
	return _finish_gear(image)


static func _create_ring_texture() -> Texture2D:
	var image := _new_gear_image()
	var silver := Color(0.78, 0.80, 0.84, 1.0)
	var silver_dark := Color(0.52, 0.55, 0.60, 1.0)
	var stone := Color(0.32, 0.56, 0.90, 1.0)
	var glint := Color(0.75, 0.90, 1.0, 1.0)

	# Band: an annulus around (7.5, 9.5), lit on the left and shadowed on the
	# right. Drawn from the radius so it reads as round at 16px rather than as
	# four straight sides.
	var centre := Vector2(7.5, 9.5)
	for y in GEAR_ICON_SIZE.y:
		for x in GEAR_ICON_SIZE.x:
			var d := Vector2(x, y).distance_to(centre)
			if d <= 4.3 and d >= 2.7:
				PixelArt.set_pixel(image, x, y, silver if x < 7.5 else silver_dark)
	# Setting and stone on top of the band.
	PixelArt.fill_rect(image, 6, 3, 9, 5, silver_dark)
	PixelArt.fill_rect(image, 7, 3, 8, 4, stone)
	PixelArt.set_pixel(image, 7, 3, glint)
	return _finish_gear(image)
