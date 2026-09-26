// Inverted-hull ink outline for the toon style (docs/style-study/mage_toon.md).
//
// Use as the `next_pass` of a surface material (ToonMaterials3D does). The pass
// draws the mesh again with front faces culled, every vertex pushed out along
// its normal by a constant width in screen pixels, so only a rim around the
// silhouette and around overlapping parts shows. The push happens in clip
// space after the model-view-projection, so it works for skinned meshes
// (Godot skins the vertex buffer before vertex() runs), for the orthographic
// game camera and for perspective cameras alike.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, fog_disabled;

uniform vec4 outline_color : source_color = vec4(0.078, 0.047, 0.110, 1.0);
// Line width in pixels at `reference_height`.
uniform float outline_width_px : hint_range(0.0, 12.0) = 2.0;
// Viewport height the width is authored for; 0 keeps it in real pixels. The
// game renders at the window size (stretch mode canvas_items), so 900, the
// design height, keeps the line proportional on a bigger window.
uniform float reference_height = 900.0;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec3 view_normal = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Screen direction of the normal, measured in pixels so x and y agree.
	vec2 dir = (PROJECTION_MATRIX * vec4(view_normal, 0.0)).xy * VIEWPORT_SIZE;
	float len = length(dir);
	if (len > 1e-6) {
		float width = outline_width_px;
		if (reference_height > 0.0) {
			width *= VIEWPORT_SIZE.y / reference_height;
		}
		clip.xy += (dir / len) * (2.0 * width / VIEWPORT_SIZE) * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
