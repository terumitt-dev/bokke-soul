shader_type spatial;
// 世界のメッシュ (面)。歩いて確かめた所は、暖かく普通に見える。まだの所は、冷たい色で暗く沈む。
// 確かめた所の縁は、スキャンの前線として、うっすら光る。
// 落ちた時は、世界全体が暗く沈み (崩れ)、戻った篝火から広がる波が通った所から、元の明るさへ戻る

uniform sampler2D reveal_tex : filter_linear, repeat_disable;
uniform sampler2D prev_reveal_tex : filter_linear, repeat_disable;
uniform vec2 reveal_origin;
uniform vec2 reveal_size;
uniform vec4 albedo : source_color = vec4(0.4, 0.38, 0.35, 1.0);
uniform vec4 unexplored_tint : source_color = vec4(0.5, 0.6, 0.8, 1.0);  // まだの所の色味
uniform float unexplored_brightness = 0.14;  // まだの所の明るさ (確かめた所を 1 として)
uniform vec4 edge_color : source_color = vec4(0.95, 0.85, 0.6, 1.0);
uniform float edge_glow = 0.18;  // 前線の光の強さ (0 で光らない)
uniform sampler2D aerial_tex : source_color, filter_linear_mipmap, repeat_disable;  // 航空写真 (地形の範囲に重なる)
uniform vec4 aerial_rect = vec4(0.0, 0.0, 1.0, 1.0);  // 写真の範囲 (西北の角の x, z と、東西、南北の長さ)
uniform float aerial_mix = 0.0;  // 1 で写真の色、0 で単色 (写真がない世界)
uniform vec4 pulse_color : source_color = vec4(1.0, 0.9, 0.6, 1.0);

#include "res://shaders/scan_wave.gdshaderinc"

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (v_world.xz - reveal_origin) / reveal_size;
	float dist = distance(v_world.xz, pulse_center.xz);
	float passed = wave_passed(dist);
	float reveal = wave_reveal(texture(prev_reveal_tex, uv).r, texture(reveal_tex, uv).r, passed);
	float broken = wave_broken(passed);

	vec2 aerial_uv = (v_world.xz - aerial_rect.xy) / aerial_rect.zw;
	vec3 base = mix(albedo.rgb, texture(aerial_tex, aerial_uv).rgb, aerial_mix);
	vec3 hidden = base * unexplored_tint.rgb * unexplored_brightness;
	ALBEDO = mix(hidden, base, reveal) * (1.0 - 0.8 * broken);
	ROUGHNESS = 1.0;

	// 確かめた所の縁 (値が 0.15〜0.5 の細い帯) を、うっすら光らせる。波の縁は、もっと強く光る
	float edge = smoothstep(0.1, 0.25, reveal) * (1.0 - smoothstep(0.25, 0.5, reveal));
	float ring = wave_ring(dist);
	EMISSION = edge_color.rgb * edge * edge_glow + pulse_color.rgb * ring * 0.7;
}
