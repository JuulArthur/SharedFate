shader_type canvas_item;

// Screen grade for the pre-render test (docs/style-study/prerender_crypt.md):
// one colour grade over background and characters alike, so the real-time mage
// and the painting share a look, plus a vignette.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float saturation = 0.86;
uniform float contrast = 1.07;
uniform vec3 lift = vec3(0.0, 0.006, 0.016);
uniform vec3 gain = vec3(1.05, 1.0, 0.95);
uniform float vignette = 0.6;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(l), c, saturation);
	c = (c - 0.5) * contrast + 0.5;
	c = c * gain + lift * (1.0 - c);
	vec2 q = SCREEN_UV - 0.5;
	float vig = 1.0 - vignette * smoothstep(0.35, 0.85, length(q * vec2(1.25, 1.0)));
	COLOR = vec4(clamp(c * vig, 0.0, 1.0), 1.0);
}
