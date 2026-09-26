class_name ToonMaterials3D
extends RefCounted

## Style study (docs/style-study/mage_toon.md): turns an imported glb into the
## cel-shaded toon look. Every surface of every `MeshInstance3D` under a node
## gets a `ShaderMaterial` on `shaders/3d/toon.gdshader` carrying the albedo
## (and emission) of the glTF material it replaces, with the ink outline
## (`shaders/3d/toon_outline.gdshader`) as its `next_pass`. The toon material is
## set as a surface override, so `SoulBodies3D.transfer_weapon` carries it to
## the player's held weapon, and `material_overlay` stays free for HitFlash3D
## and the hover highlight. Materials are keyed by name: every surface that
## used `Mage_Robe` shares one toon material, and `overrides` can tune a
## material by name (for example `{"Mage_Gem": {"rim_strength": 0.0}}`).
##
## Skinned meshes work unchanged: Godot skins the vertices before the shaders'
## vertex() runs, so the outline follows the animated pose.
##
##     var stats := ToonMaterials3D.apply(model)
##     # {"meshes": 2, "surfaces": 15, "toon": 15, "outlined": 15, "materials": 14}

const TOON_SHADER: Shader = preload("res://shaders/3d/toon.gdshader")
const OUTLINE_SHADER: Shader = preload("res://shaders/3d/toon_outline.gdshader")
const OUTLINE_COLOR := Color(0.078, 0.047, 0.110, 1.0)
const OUTLINE_WIDTH_PX := 2.0
## Small face details (eyes, hair locks, skin) would drown in a full-width line;
## materials whose name ends in one of these get FINE_OUTLINE_WIDTH_PX unless
## `overrides` sets "outline_width_px" for them.
const FINE_LINE_SUFFIXES: PackedStringArray = ["_Eye", "_Hair", "_Skin"]
const FINE_OUTLINE_WIDTH_PX := 1.0


## Replaces the materials under `root`. Returns counts of meshes, surfaces, toon
## surfaces, outlined surfaces and distinct toon materials.
static func apply(root: Node, overrides: Dictionary = {}, outline_width_px: float = OUTLINE_WIDTH_PX,
		outline_color: Color = OUTLINE_COLOR) -> Dictionary:
	var stats := {"meshes": 0, "surfaces": 0, "toon": 0, "outlined": 0, "materials": 0}
	if root == null:
		return stats
	var outline := make_outline_material(outline_width_px, outline_color)
	var fine_outline := make_outline_material(minf(outline_width_px, FINE_OUTLINE_WIDTH_PX), outline_color)
	var cache := {}
	var meshes: Array[MeshInstance3D] = []
	_gather(root, meshes)
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		stats["meshes"] = int(stats["meshes"]) + 1
		for surface in range(mesh_instance.mesh.get_surface_count()):
			stats["surfaces"] = int(stats["surfaces"]) + 1
			var source := mesh_instance.get_active_material(surface)
			var key := _material_key(source, surface)
			var toon: ShaderMaterial = cache.get(key) as ShaderMaterial
			if toon == null:
				var settings: Dictionary = overrides.get(key, {}) as Dictionary
				toon = make_toon_material(source, settings)
				if bool(settings.get("outline", true)):
					if settings.has("outline_width_px"):
						toon.next_pass = make_outline_material(float(settings["outline_width_px"]), outline_color)
					elif _is_fine_detail(key):
						toon.next_pass = fine_outline
					else:
						toon.next_pass = outline
				cache[key] = toon
			mesh_instance.set_surface_override_material(surface, toon)
			stats["toon"] = int(stats["toon"]) + 1
			if toon.next_pass != null:
				stats["outlined"] = int(stats["outlined"]) + 1
	stats["materials"] = cache.size()
	return stats


## A toon material with the colour of `source` (a BaseMaterial3D from the glTF
## importer, or null for white). `settings` may set any toon uniform by name.
static func make_toon_material(source: Material, settings: Dictionary = {}) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = TOON_SHADER
	material.resource_name = (source.resource_name if source != null else "Toon") + "_Toon"
	var base := source as BaseMaterial3D
	if base != null:
		material.set_shader_parameter("albedo", base.albedo_color)
		if base.emission_enabled:
			material.set_shader_parameter("emission", base.emission)
			material.set_shader_parameter("emission_energy", base.emission_energy_multiplier)
	for uniform_name: String in settings:
		if uniform_name == "outline" or uniform_name == "outline_width_px":
			continue
		material.set_shader_parameter(uniform_name, settings[uniform_name])
	return material


static func make_outline_material(width_px: float = OUTLINE_WIDTH_PX,
		color: Color = OUTLINE_COLOR) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = OUTLINE_SHADER
	material.resource_name = "Toon_Outline"
	material.set_shader_parameter("outline_width_px", width_px)
	material.set_shader_parameter("outline_color", color)
	return material


## True when `surface` of `mesh_instance` renders with the toon shader.
static func is_toon_surface(mesh_instance: MeshInstance3D, surface: int) -> bool:
	var material := mesh_instance.get_surface_override_material(surface) as ShaderMaterial
	return material != null and material.shader == TOON_SHADER


## True when that surface also draws the ink outline.
static func has_outline(mesh_instance: MeshInstance3D, surface: int) -> bool:
	var material := mesh_instance.get_surface_override_material(surface) as ShaderMaterial
	if material == null:
		return false
	var outline := material.next_pass as ShaderMaterial
	return outline != null and outline.shader == OUTLINE_SHADER


## Line width of every outline under `root` (for zoom or hover emphasis); fine
## detail lines keep half the width.
static func set_outline_width(root: Node, width_px: float) -> void:
	var meshes: Array[MeshInstance3D] = []
	_gather(root, meshes)
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		for surface in range(mesh_instance.mesh.get_surface_count()):
			if has_outline(mesh_instance, surface):
				var material := mesh_instance.get_surface_override_material(surface) as ShaderMaterial
				var width := width_px * 0.5 if _is_fine_detail(_material_key_of_toon(material)) else width_px
				(material.next_pass as ShaderMaterial).set_shader_parameter("outline_width_px", width)


static func _is_fine_detail(key: String) -> bool:
	for suffix in FINE_LINE_SUFFIXES:
		if key.ends_with(suffix):
			return true
	return false


static func _material_key(source: Material, surface: int) -> String:
	if source != null and not source.resource_name.is_empty():
		return source.resource_name
	return "surface_%d" % surface


static func _material_key_of_toon(material: ShaderMaterial) -> String:
	return material.resource_name.trim_suffix("_Toon")


static func _gather(node: Node, out: Array[MeshInstance3D]) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		out.append(mesh_instance)
	for child in node.get_children():
		_gather(child, out)
