shader_type canvas_item;
render_mode unshaded;

// Row per clip: pivot/count header, then rectangle/end-time pairs per frame.
uniform sampler2D clips : filter_nearest, repeat_disable;
uniform vec2 atlas_size;
uniform bool shadow_pass = false;

void vertex() {
	float scale = INSTANCE_CUSTOM.w;
	if (shadow_pass) {
		VERTEX = (UV - vec2(0.5)) * vec2(25.0, 11.0) * scale + vec2(0.0, -2.0);
	} else {
		int clip = int(INSTANCE_CUSTOM.x);
		vec4 header = texelFetch(clips, ivec2(0, clip), 0);
		vec4 region = vec4(0.0);
		for (int frame = 0; frame < int(header.z); frame++) {
			region = texelFetch(clips, ivec2(1 + frame * 2, clip), 0);
			float end_ms = texelFetch(clips, ivec2(2 + frame * 2, clip), 0).r;
			if (INSTANCE_CUSTOM.y < end_ms) {
				break;
			}
		}
		VERTEX = (UV * region.zw - header.xy) * scale;
		// Normalize origin/extent separately, matching Canvas texture rectangles.
		// Dividing their sum changes nearest-texel ties at half-pixel positions.
		UV = region.xy / atlas_size + UV * (region.zw / atlas_size);
	}
	COLOR.a *= INSTANCE_CUSTOM.z;
}
