extends SceneTree

# 実行: godot --headless --path game --script res://tests/world_registry_test.gd
# 遊べるマップの一覧と、隣り合うマップの見つけ方 (測量座標の原点と大きさから)、端の判定、座標の直しを確かめる。
# 配置は、実際に使っている 5 つのマップ (08OF3006 とその東西南北) と同じ

const DIR := "user://test_world_registry"
# 名前: [原点 (東, 北, 標高), 大きさ (幅, 高さ, 奥行き)]
const MAPS := {
	"center": [[42400.25, -129299.75, 1061.53], [399.0, 65.0, 299.0]],
	"west": [[42000.25, -129299.75, 1004.89], [399.0, 120.0, 299.0]],
	"east": [[42800.25, -129299.75, 1019.66], [399.0, 124.5, 299.0]],
	"south": [[42400.25, -129599.75, 991.94], [399.0, 84.9, 299.0]],
	"north": [[42400.25, -128999.75, 1062.41], [399.0, 118.7, 299.0]],
}

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _make(name: String, sidecar: Variant) -> void:
	_write("%s/%s.glb" % [DIR, name], "x")  # 中身は使わない。一覧は、.json だけを読む
	if sidecar != null:
		_write("%s/%s.json" % [DIR, name], JSON.stringify(sidecar))


func _sidecar(id: String, origin: Array, size: Array, name := "") -> Dictionary:
	return {"world_id": id, "name": name if not name.is_empty() else id, "origin": origin, "size": size}


func _by_id(entries: Array[Dictionary], id: String) -> Dictionary:
	for entry in entries:
		if entry.world_id == id:
			return entry
	return {}


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	for key: String in MAPS:
		_make(key, _sidecar("map-" + key, MAPS[key][0], MAPS[key][1], key))
	_make("no_sidecar", null)
	_make("no_id", {"origin": [1, 2, 3], "size": [10, 10, 10]})
	_make("no_origin", {"world_id": "x-no-origin", "size": [10, 10, 10]})
	_make("bad_size", {"world_id": "x-bad-size", "origin": [1, 2, 3], "size": [0, 10, 10]})
	_make("far", _sidecar("map-far", [50000.0, -129299.75, 1000.0], [399.0, 50.0, 299.0]))
	_make("diagonal", _sidecar("map-diagonal", [42800.25, -128999.75, 1000.0], [399.0, 50.0, 299.0]))  # 北東の角だけで接する
	_write("%s/not_a_world.txt" % DIR, "x")

	var entries := WorldRegistry.scan(DIR)
	var ids: Array = entries.map(func(e: Dictionary) -> String: return e.world_id)
	check(ids.size() == 7 and "map-center" in ids and "map-far" in ids and "map-diagonal" in ids, "世界の名前と、原点と大きさがある世界だけが、一覧に入る (%s)" % [ids])
	check(not ("x-no-origin" in ids) and not ("x-bad-size" in ids), "原点がない、大きさが不正な世界は、入らない")
	check(_by_id(entries, "map-center").name == "center", "マップの名前も入る")

	var center := _by_id(entries, "map-center")
	var near := WorldRegistry.neighbors(entries, center)
	check(near.size() == 4, "中心のマップには、東西南北に、隣がある (%d)" % near.size())
	check(near.east.world_id == "map-east" and near.west.world_id == "map-west", "東と西の隣が、正しい")
	check(near.north.world_id == "map-north" and near.south.world_id == "map-south", "北と南の隣が、正しい")
	var west_near := WorldRegistry.neighbors(entries, _by_id(entries, "map-west"))
	check(west_near.size() == 1 and west_near.east.world_id == "map-center", "西のマップの隣は、東の中心だけ")
	var diagonal_near := WorldRegistry.neighbors(entries, _by_id(entries, "map-diagonal"))
	check(diagonal_near.size() == 2 and diagonal_near.south.world_id == "map-east" and diagonal_near.west.world_id == "map-north", "辺が重なる、東のマップ (南) と、北のマップ (西) だけが、隣")
	check(not near.values().any(func(e: Dictionary) -> bool: return e.world_id == "map-diagonal"), "中心のマップと、角だけで接するマップは、隣ではない")
	check(not near.values().any(func(e: Dictionary) -> bool: return e.world_id == "map-far"), "遠いマップは、隣ではない")
	check(WorldRegistry.neighbors(entries, _by_id(entries, "map-far")).is_empty(), "遠いマップには、隣がない")

	# 端の判定 (ゲームの座標: x は東、z は南が 0、北が -奥行き)
	var size: Vector3 = center.size
	check(WorldRegistry.edge_toward(center, Vector3(size.x - 1.0, 5.0, -150.0), 2.0, near) == "east", "東の端の近くは、east")
	check(WorldRegistry.edge_toward(center, Vector3(1.0, 5.0, -150.0), 2.0, near) == "west", "西の端の近くは、west")
	check(WorldRegistry.edge_toward(center, Vector3(200.0, 5.0, -size.z + 1.0), 2.0, near) == "north", "北の端 (z が -奥行きに近い) は、north")
	check(WorldRegistry.edge_toward(center, Vector3(200.0, 5.0, -1.0), 2.0, near) == "south", "南の端 (z が 0 に近い) は、south")
	check(WorldRegistry.edge_toward(center, Vector3(200.0, 5.0, -150.0), 2.0, near) == "", "真ん中は、端ではない")
	check(WorldRegistry.edge_toward(center, Vector3(1.0, 5.0, -150.0), 2.0, {}) == "", "隣がない方角の端は、出口にならない")
	check(WorldRegistry.edge_toward(center, Vector3(1.0, 5.0, -1.0), 2.0, near) != "", "角では、近い方の端を選ぶ")

	# 座標の直し: 測量座標で同じ場所。東の隣へは、東へ進んだ分だけ、x が小さくなる
	var east_entry := _by_id(entries, "map-east")
	var here := Vector3(size.x - 1.0, 40.0, -100.0)
	var there := WorldRegistry.convert_position(center, east_entry, here)
	# 中心の東端 (測量 42798.25) は、東のマップの原点 (42800.25) の 2 m 手前 = x は -2
	check(is_equal_approx(there.x, -2.0), "東のマップの座標では、x が、原点の手前 2 m (隙間 1 m を含む): %s" % [there])
	check(is_equal_approx(there.z, here.z), "南北は、変わらない (原点の北が同じ)")
	var height_shift := (MAPS.center[0][2] - MAPS.east[0][2])
	check(is_equal_approx(there.y, here.y + height_shift), "標高は、測量の標高で同じ。原点の標高の差だけ、高さの数字が変わる")
	var back := WorldRegistry.convert_position(east_entry, center, there)
	check(back.is_equal_approx(here), "行って、戻ると、元の位置 (往復で変わらない)")
	var north_entry := _by_id(entries, "map-north")
	var up := WorldRegistry.convert_position(center, north_entry, Vector3(200.0, 10.0, -size.z + 1.0))
	check(up.z > -3.0 and up.z < 3.0, "北の端から北のマップへ行くと、北のマップの南の端 (z が 0 の近く) に出る: %s" % [up])
	var down := WorldRegistry.convert_position(north_entry, center, up)
	check(down.is_equal_approx(Vector3(200.0, 10.0, -size.z + 1.0)), "戻ると、元の位置 (南北でも、往復で変わらない)")

	for file in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))
	quit(1 if failures.size() > 0 else 0)
