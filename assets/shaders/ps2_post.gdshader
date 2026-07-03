// PS2-era post look for BOTH camera views (P5 Phase 1+3).
// Posterized color, ordered Bayer dither, mild vignette — Wings of War vibe —
// plus analog signal static (snow / scanlines / row tearing) scaled by
// static_intensity, driven from DebugHUD off the drone's signal quality.
// Lives on a CanvasLayer BELOW the HUD layer so UI stays crisp, but ABOVE the
// dead-feed layer so full static renders over the crash freeze frame.
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
// Analog static: 0 = clean feed, 1 = full snow (link dead).
uniform float static_intensity : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Time goes in as a third hash dimension, NOT a coordinate offset — offsetting
// just translates the same noise field, which reads as one big scrolling
// texture instead of TV static re-rolling every frame.
float hash3(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

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

	// Horizontal tear: a few of 40 rows shift sideways; more rows and larger
	// shifts as the signal degrades. Noise refreshes at ~24 Hz (analog feed,
	// not per-render-frame shimmer). Wrapped: raw TIME grows unboundedly and
	// the sin() hash loses float precision on large inputs, degenerating the
	// snow into structured sliding bands after a few minutes of play.
	float t = mod(floor(TIME * 24.0), 256.0);
	float row = floor(SCREEN_UV.y * 40.0);
	if (hash(vec2(row, t)) > 1.0 - 0.3 * static_intensity) {
		uv.x += (hash(vec2(t, row)) - 0.5) * 0.2 * static_intensity;
	}
	vec3 col = texture(screen_tex, uv).rgb;

	// Ordered 4x4 Bayer dither, applied before posterization.
	int idx = int(mod(screen_px.y, 4.0)) * 4 + int(mod(screen_px.x, 4.0));
	float threshold = BAYER[idx] / 16.0 - 0.5;
	col += threshold * dither_strength / color_levels;
	col = floor(col * color_levels + 0.5) / color_levels;

	// Mild corner vignette.
	vec2 d = SCREEN_UV - 0.5;
	col *= 1.0 - vignette_strength * dot(d, d) * 2.0;

	// White-noise snow and scanlines over the finished frame. Uses the
	// pixel-snapped coords so the static grain matches the pixelation.
	float snow = hash3(vec3(screen_px, t));
	col = mix(col, vec3(snow), clamp(static_intensity, 0.0, 1.0) * 0.9);
	col *= 1.0 - 0.15 * static_intensity * (0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159));

	COLOR = vec4(col, 1.0);
}
