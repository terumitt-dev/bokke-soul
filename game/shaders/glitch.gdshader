shader_type canvas_item;
// 画面全体のノイズ。「位置を見失った」時に、画面が暗くなり、走査線がずれ、色がにじむ。
// 世界の点が視界に入らなくても (世界の下へ落ちた時など)、何が起きたかが伝わる

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float time_seconds = 0.0;
uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.5, 1.0);

float rand(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	// 帯ごとに、画面を横へずらす (走査線のずれ)。時間で、ずれる帯が変わる
	float band = floor(UV.y * 28.0);
	float flicker = floor(time_seconds * 14.0);
	float r = rand(vec2(band, flicker));
	float shift = (r - 0.5) * 0.18 * intensity * step(0.62, r);
	vec2 uv = vec2(UV.x + shift, UV.y);

	// 色のにじみ (赤と青を、左右へずらす)
	float split = 0.012 * intensity;
	vec3 color = vec3(
		texture(screen_texture, uv + vec2(split, 0.0)).r,
		texture(screen_texture, uv).g,
		texture(screen_texture, uv - vec2(split, 0.0)).b);

	// 暗くなる (中心より、縁がさらに暗い)
	float edge = distance(UV, vec2(0.5));
	color *= 1.0 - intensity * (0.45 + 0.4 * edge);

	// 細かい走査線と、ときどき走る明るい線
	color *= 1.0 - intensity * 0.12 * step(0.5, fract(UV.y * 220.0));
	float streak = step(0.985, rand(vec2(floor(UV.y * 90.0), flicker + 3.0)));
	color = mix(color, tint.rgb, streak * intensity * 0.6);

	COLOR = vec4(color, 1.0);
}
