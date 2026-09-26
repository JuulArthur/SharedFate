shader_type spatial;

// Pre-rendered background on proxy geometry (docs/style-study/prerender_crypt.md).
//
// Every proxy surface shows the Blender render projected from the game camera:
// the camera only ever translates (CameraRig3D never rotates), so an
// orthographic projection along the same axes maps each world point to the
// pixel that painted it, and the depth buffer comes from the real geometry.
//
// Light: the painting already holds all the static light. The moon (the one
// DirectionalLight) never adds anything; where a character blocks it, its
// shadow takes the moonlight pass away. Other lights (spells) add the diffuse
// colour pass lit by the proxy normal. Fire and sigil passes are scaled by
// fire_level and sigil_level so the flames flicker and the circle pulses.

render_mode ambient_light_disabled, specular_disabled, fog_disabled, diffuse_lambert;

uniform sampler2D color_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D moon_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D fire_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D sigil_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;

uniform vec3 cam_center;
uniform vec3 cam_right = vec3(0.70711, 0.0, -0.70711);
uniform vec3 cam_up = vec3(-0.40558, 0.81915, -0.40558);
uniform vec2 view_size = vec2(32.0, 17.4);

uniform float moon_shadow = 0.85;
uniform float fire_level = 1.0;
uniform float sigil_level = 1.0;
uniform float dynamic_light_gain = 1.0;
// 1.0 shows the proxies as plain grey geometry (debug view).
uniform float debug_geometry = 0.0;

varying vec3 world_pos;
varying vec3 painted;
varying vec3 moonlit;
varying vec3 diffuse_colour;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 d = world_pos - cam_center;
	vec2 uv = vec2(dot(d, cam_right) / view_size.x + 0.5, 0.5 - dot(d, cam_up) / view_size.y);
	vec3 base = texture(color_tex, uv).rgb;
	vec3 fire = texture(fire_tex, uv).rgb;
	vec3 sigil = texture(sigil_tex, uv).rgb;
	moonlit = texture(moon_tex, uv).rgb;
	diffuse_colour = texture(albedo_tex, uv).rgb;
	painted = max(base + fire * (fire_level - 1.0) + sigil * (sigil_level - 1.0), vec3(0.0));
	if (debug_geometry > 0.5) {
		float shade = 0.2 + 0.35 * clamp(dot(NORMAL, normalize(vec3(0.3, 1.0, 0.6))), 0.0, 1.0);
		painted = vec3(shade) * mix(vec3(0.75, 0.8, 0.9), vec3(0.9, 0.85, 0.7), step(0.5, fract(world_pos.y * 2.0)));
		moonlit = painted * 0.5;
		diffuse_colour = painted;
	}
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += max(painted - moonlit * moon_shadow * (1.0 - ATTENUATION), vec3(0.0));
	} else {
		float ndl = max(dot(NORMAL, LIGHT), 0.0);
		DIFFUSE_LIGHT += diffuse_colour * LIGHT_COLOR * ATTENUATION * ndl * dynamic_light_gain;
	}
}
