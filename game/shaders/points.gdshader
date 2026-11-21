shader_type spatial;
render_mode unshaded, cull_disabled;
// 世界の点。歩いて確かめた所は、すべての点が出る。まだの所は、ごく一部の点だけが、うっすらと残る。
// 点の大きさは、遠いほど小さい (近くが大きくなりすぎないよう、上限もある)。
// 元のデータは等間隔の格子なので、位置を少しばらして、格子が見えないようにしている

uniform sampler2D reveal_tex : filter_linear, repeat_disable;
uniform vec2 reveal_origin;
uniform vec2 reveal_size;
uniform vec3 player_position;
uniform float point_size_px = 2.4;
uniform float unexplored_density = 0.05;  // まだの所で、残る点の割合
uniform float jitter = 0.45;  // 点の位置のばらつき (m)
uniform vec4 point_color : source_color = vec4(0.92, 0.88, 0.78, 1.0);
uniform vec4 unexplored_color : source_color = vec4(0.45, 0.5, 0.62, 1.0);
uniform float time_seconds = 0.0;

varying float v_keep;
varying float v_reveal;
varying float v_near;

// 整数のハッシュ (PCG 系)。sin に頼る乱数は、点の数が多いと、GPU によって精度が落ちて偏る。
// id と、用途ごとの salt から、0〜1 の値を作る
float rand(uint id, uint salt) {
	uint state = id * 747796405u + salt * 2891336453u + 1u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	word = (word >> 22u) ^ word;
	return float(word) / 4294967295.0;
}

void vertex() {
	uint id = uint(VERTEX_ID);
	// 格子が見えないよう、点ごとに決まった向きへ、少しずらす (毎回同じ)
	VERTEX += (vec3(rand(id, 1u), rand(id, 2u), rand(id, 3u)) - 0.5) * jitter;

	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = (world.xz - reveal_origin) / reveal_size;
	float reveal = textureLod(reveal_tex, uv, 0.0).r;
	// 確かめた所ほど、多くの点が残る
	v_keep = step(rand(id, 4u), mix(unexplored_density, 1.0, reveal));
	v_reveal = reveal;
	v_near = 1.0 - smoothstep(10.0, 80.0, distance(world, player_position));

	// まだの所の点は、ゆらいで見える (ノイズ)。確かめた所は、動かない
	uint tick = uint(floor(time_seconds * 3.0));
	VERTEX += (vec3(rand(id, 5u + tick * 3u), rand(id, 6u + tick * 3u), rand(id, 7u + tick * 3u)) - 0.5) * (1.0 - reveal) * 0.5;

	float depth = max(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z, 0.5);
	POINT_SIZE = clamp(point_size_px * 14.0 / depth, 1.0, point_size_px * 1.2) * v_keep;
}

void fragment() {
	if (v_keep < 0.5) {
		discard;
	}
	// 確かめた所は、色がはっきり。まだの所は、弱く、青白く
	vec3 color = mix(unexplored_color.rgb * 0.7, point_color.rgb, v_reveal);
	ALBEDO = color * mix(0.7, 1.0, v_near);
}
