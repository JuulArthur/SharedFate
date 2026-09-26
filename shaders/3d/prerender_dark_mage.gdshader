shader_type spatial;

// Dark fantasy retint of the soft mage for the pre-render test
// (docs/style-study/prerender_crypt.md). The glb keeps its purple palette;
// this sorts each colour into robe, trim, gold, skin or neutral by hue and
// maps it onto a darker palette, keeping the baked fold shading and ambient
// occlusion as a brightness ratio. The staff crystal glows crimson.

uniform vec4 base_color : source_color = vec4(1.0);
uniform bool use_vertex_color = false;
uniform bool is_gem = false;
uniform vec4 robe : source_color = vec4(0.17, 0.125, 0.165, 1.0);
uniform vec4 trim : source_color = vec4(0.42, 0.1, 0.11, 1.0);
uniform vec4 metal : source_color = vec4(0.46, 0.36, 0.22, 1.0);
uniform vec4 skin : source_color = vec4(0.74, 0.7, 0.66, 1.0);
uniform vec4 under : source_color = vec4(0.24, 0.235, 0.26, 1.0);
uniform vec4 gem_glow : source_color = vec4(1.0, 0.16, 0.08, 1.0);
uniform float gem_energy = 3.0;
uniform float rim_amount = 0.35;

vec3 to_srgb(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

vec3 to_linear(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

vec3 rgb2hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float hue_near(float h, float centre, float width) {
	float dh = abs(fract(h - centre + 0.5) - 0.5);
	return 1.0 - smoothstep(width * 0.6, width, dh);
}

void fragment() {
	vec3 src = to_srgb(use_vertex_color ? COLOR.rgb : base_color.rgb);
	vec3 hsv = rgb2hsv(src);
	float h = hsv.x;
	float s = hsv.y;
	float v = hsv.z;
	float w_purple = hue_near(h, 0.74, 0.12) * smoothstep(0.12, 0.25, s);
	float w_gold = hue_near(h, 0.12, 0.06) * smoothstep(0.35, 0.5, s);
	float w_skin = hue_near(h, 0.05, 0.08) * smoothstep(0.08, 0.14, s) * (1.0 - smoothstep(0.4, 0.5, s)) * smoothstep(0.5, 0.6, v);
	float w_neutral = 1.0 - smoothstep(0.1, 0.18, s);
	vec3 purple = mix(robe.rgb, trim.rgb, smoothstep(0.66, 0.8, v)) * (v / 0.55);
	vec3 gold = metal.rgb * (v / 0.85);
	vec3 flesh = skin.rgb * (v / 0.86);
	vec3 grey = mix(under.rgb * (v / 0.55), vec3(0.62, 0.62, 0.66) * (v / 0.8), smoothstep(0.7, 0.8, v));
	float total = w_purple + w_gold + w_skin + w_neutral;
	vec3 out_col = to_linear(src) * 0.25;
	if (total > 0.01) {
		out_col = (purple * w_purple + gold * w_gold + flesh * w_skin + grey * w_neutral) / total;
		out_col = to_linear(clamp(to_srgb(out_col), 0.0, 1.0));
	}
	ALBEDO = out_col;
	ROUGHNESS = 0.8;
	RIM = rim_amount;
	RIM_TINT = 0.3;
	if (is_gem) {
		ALBEDO = gem_glow.rgb * 0.3;
		EMISSION = gem_glow.rgb * gem_energy;
	}
}
