// 波と崩れの計算。点 (points.gdshader) と面 (terrain_reveal.gdshader) で共通。
// 点は頂点で、面はフラグメントで計算するので、同じ式を 1 か所にまとめている。
//
//   dist:  波の中心 (pulse_center) からの水平の距離 (m)
//   passed: 波が通り過ぎた所は 1。波の範囲を使わない間は 0 (崩れは、世界全体にかかる)

uniform float disturbance = 0.0;  // 世界の崩れ具合 (0〜1)
uniform float pulse_enabled = 0.0;  // 波の範囲を使う間 (波が広がっている間と、遠くの崩れが戻るまで)
uniform vec3 pulse_center;
uniform float pulse_radius = 0.0;  // 波の、いまの半径 (m)
uniform float pulse_edge = 3.0;  // 波の縁の幅 (m)
uniform float ring_strength = 0.0;  // 波の縁の光の強さ (0〜1)

float wave_passed(float dist) {
	return pulse_enabled * (1.0 - smoothstep(pulse_radius - pulse_edge, pulse_radius, dist));
}

// 波が通った所は新しい地図、まだの所は波の前の地図。波の範囲を使わない間は、新しい地図
float wave_reveal(float reveal_prev, float reveal_now, float passed) {
	return mix(reveal_prev, reveal_now, mix(1.0, passed, pulse_enabled));
}

float wave_broken(float passed) {
	return disturbance * (1.0 - passed);
}

float wave_ring(float dist) {
	return exp(-pow((dist - pulse_radius) / pulse_edge, 2.0)) * ring_strength * pulse_enabled;
}
