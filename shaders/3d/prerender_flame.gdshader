shader_type spatial;

// Animated flame overlay for the pre-rendered background
// (docs/style-study/prerender_crypt.md). The painting holds a still fire; this
// camera-facing quad adds the motion on top, as the Infinity Engine games laid
// animated overlays over their painted areas. Additive, depth-tested, so a
// character in front hides it.

render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec4 hot : source_color = vec4(1.0, 0.86, 0.5, 1.0);
uniform vec4 cool : source_color = vec4(1.0, 0.28, 0.04, 1.0);
uniform float intensity = 1.4;
uniform float seed = 0.0;
uniform float speed = 1.6;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	float y = 1.0 - UV.y;
	float t = TIME * speed + seed * 7.13;
	float n = texture(noise_tex, vec2(UV.x * 1.2 + seed, y * 0.8 - t)).r;
	float n2 = texture(noise_tex, vec2(UV.x * 2.3 + 0.37 + seed, y * 1.7 - t * 1.4)).r;
	float x = (UV.x - 0.5) * 2.0 + (n2 - 0.5) * 0.5 * y;
	float width = mix(0.85, 0.08, pow(y, 0.75));
	float shape = 1.0 - smoothstep(width * 0.45, width, abs(x));
	float body = shape * (1.0 - smoothstep(0.2, 1.0, y + (n - 0.5) * 0.55)) * smoothstep(0.0, 0.12, y);
	vec3 col = mix(hot.rgb, cool.rgb, clamp(y * 1.4 + (n - 0.5) * 0.5, 0.0, 1.0));
	ALBEDO = col * body * intensity;
}
