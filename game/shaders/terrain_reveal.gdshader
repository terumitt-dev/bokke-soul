shader_type spatial;
// 世界のメッシュ (面)。歩いて確かめた所は、暖かく普通に見える。まだの所は、冷たい色で暗く沈む。
// 確かめた所の縁は、スキャンの前線として、うっすら光る

uniform sampler2D reveal_tex : filter_linear, repeat_disable;
uniform vec2 reveal_origin;
uniform vec2 reveal_size;
uniform vec4 albedo : source_color = vec4(0.4, 0.38, 0.35, 1.0);
uniform vec4 unexplored_tint : source_color = vec4(0.5, 0.6, 0.8, 1.0);  // まだの所の色味
uniform float unexplored_brightness = 0.14;  // まだの所の明るさ (確かめた所を 1 として)
uniform vec4 edge_color : source_color = vec4(0.95, 0.85, 0.6, 1.0);
uniform float edge_glow = 0.18;  // 前線の光の強さ (0 で光らない)

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (v_world.xz - reveal_origin) / reveal_size;
	float reveal = texture(reveal_tex, uv).r;
	vec3 base = albedo.rgb;
	vec3 hidden = base * unexplored_tint.rgb * unexplored_brightness;
	ALBEDO = mix(hidden, base, reveal);
	ROUGHNESS = 1.0;
	// 確かめた所の縁 (値が 0.15〜0.5 の細い帯) を、うっすら光らせる
	float edge = smoothstep(0.1, 0.25, reveal) * (1.0 - smoothstep(0.25, 0.5, reveal));
	EMISSION = edge_color.rgb * edge * edge_glow;
}
