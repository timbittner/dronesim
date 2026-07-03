// PS2-era post look for the 3PV chase camera (P5 Phase 1).
// Posterized color, ordered Bayer dither, mild vignette — Wings of War vibe.
// Lives on a CanvasLayer BELOW the HUD layer so UI stays crisp.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
// Levels per color channel. 32 = 5 bits/channel (PS2 16-bit framebuffer feel).
uniform float color_levels : hint_range(4.0, 64.0) = 16.0;
uniform float dither_strength : hint_range(0.0, 2.0) = 1.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.8;
// Screen pixels per sampled texel. 1 = native; 2-3 = chunky low-res.
uniform float pixel_size : hint_range(1.0, 6.0) = 2.0;
// Slight barrel/fisheye pull toward the screen edges. 0 = off.
uniform float fisheye_strength : hint_range(0.0, 0.5) = 0.1;

const float BAYER[16] = {
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0
};

void fragment() {
	vec2 screen_px = FRAGCOORD.xy;
	// Pixelate: snap sampling to a coarse grid before quantizing.
	vec2 uv = SCREEN_UV;
	if (pixel_size > 1.0) {
		vec2 texel = SCREEN_PIXEL_SIZE * pixel_size;
		uv = (floor(SCREEN_UV / texel) + 0.5) * texel;
		screen_px = floor(screen_px / pixel_size);
	}
	// Fisheye: sample toward the center as radius grows — stretches the
	// edges outward like a lens, and keeps UVs in bounds. Applied after the
	// pixel snap so output pixels stay a uniform grid.
	vec2 c = uv - 0.5;
	uv = 0.5 + c * (1.0 - fisheye_strength * dot(c, c) * 4.0);
	vec3 col = texture(screen_tex, uv).rgb;

	// Ordered 4x4 Bayer dither, applied before posterization.
	int idx = int(mod(screen_px.y, 4.0)) * 4 + int(mod(screen_px.x, 4.0));
	float threshold = BAYER[idx] / 16.0 - 0.5;
	col += threshold * dither_strength / color_levels;
	col = floor(col * color_levels + 0.5) / color_levels;

	// Mild corner vignette.
	vec2 d = SCREEN_UV - 0.5;
	col *= 1.0 - vignette_strength * dot(d, d) * 2.0;

	COLOR = vec4(col, 1.0);
}
