// Cel-shaded toon surface for the 3D style study (docs/style-study/mage_toon.md).
//
// Flat colour regions: the diffuse term is quantised into two or three hard
// bands from N.L times the shadow attenuation, an optional rim band brightens
// grazing edges on the lit side, and the scene's ambient light is ignored so a
// colour looks the same in every level. The shadow band is written as EMISSION
// (albedo * shadow_color), so a surface no light reaches still shows its
// colour; each light adds the difference up to the lit band.
//
// The defaults are the numbers the Blender generator uses for its Shader to RGB
// + constant Color Ramp materials (tools/blender/mage_styles/mage_toon.py), so
// the Blender renders and the game agree. ToonMaterials3D sets `albedo` (and
// `emission` for glowing parts) from the imported glTF material.
shader_type spatial;
// fog_disabled: the arena's depth fog is a uniform wash at the 30 m camera boom and
// would grey the flat colours; characters stay saturated against the fogged world.
render_mode ambient_light_disabled, fog_disabled;

uniform vec4 albedo : source_color = vec4(1.0);
// 2: shadow and light only; 3: adds a mid band between the thresholds.
uniform int bands : hint_range(2, 3) = 3;
uniform float shadow_threshold : hint_range(-1.0, 1.0) = 0.08;
uniform float light_threshold : hint_range(-1.0, 1.0) = 0.62;
// Albedo multiplier in the shadow band; a cool purple keeps shadows saturated.
// Linear values (no source_color), the same numbers as the Blender ramp stops.
uniform vec4 shadow_color = vec4(0.52, 0.46, 0.70, 1.0);
// The mid band sits this far from the shadow band toward the lit band.
uniform float mid_mix : hint_range(0.0, 1.0) = 0.55;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.28;
uniform float rim_width : hint_range(0.0, 1.0) = 0.22;
uniform vec4 rim_color = vec4(1.0, 0.96, 1.0, 1.0);
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 0.0;
// 0: a light only contributes its hue (flat toon colours whatever the energy);
// 1: its colour times energy, like a physical light.
uniform float light_energy_influence : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	EMISSION = albedo.rgb * shadow_color.rgb + emission.rgb * emission_energy;
}

void light() {
	float x = dot(NORMAL, LIGHT) * ATTENUATION;
	float peak = max(max(LIGHT_COLOR.r, LIGHT_COLOR.g), max(LIGHT_COLOR.b, 1e-4));
	vec3 hue = mix(LIGHT_COLOR / peak, LIGHT_COLOR / PI, light_energy_influence);
	vec3 shadow = shadow_color.rgb;
	vec3 level = shadow;
	if (x > shadow_threshold) {
		level = (bands >= 3 && x < light_threshold) ? mix(shadow, vec3(1.0), mid_mix) : vec3(1.0);
	}
	DIFFUSE_LIGHT += hue * (level - shadow);
	float rim = step(1.0 - rim_width, 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0));
	SPECULAR_LIGHT += hue * rim_color.rgb * (rim_strength * rim * step(shadow_threshold, x));
}
