extends SceneTree

# 実行: godot --headless --path game --script res://tests/save_test.gd
# セーブ (保存と読み込み、壊れたセーブ、新しいバージョン、地図の復元、ゲームへの組み込み、タイトル画面) を確かめる。
# 本物のセーブを書き換えないよう、保存先は、このテスト専用の場所にする

const TEST_DIR := "user://test_saves"
const SAMPLE := "res://assets/sample_world.glb"

var failures: Array[String] = []


# 「休んだ」の順序を記録する (点の表現の役。on_rest が呼ばれた時に記録する)
class Recorder:
	extends Node
	var events: Array[String] = []

	func on_rest(_position: Vector3) -> void:
		events.append("rest")


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _clean() -> void:
	var dir := DirAccess.open(TEST_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		dir.remove(file)


func _initialize() -> void:
	SaveGame.directory = TEST_DIR
	_clean()
	_test_guard()
	_test_round_trip()
	_test_named_world()
	_test_areas()
	_test_legacy_import()
	_test_write_failure()
	_test_broken_and_versions()
	_test_reveal_png()
	_test_time_restore()
	await _test_game()
	await _test_failure_notice()
	await _test_close_with_failed_save()
	await _test_points_off_keeps_map()
	await _test_rebuilt_world()
	await _test_time_for_new_area()
	await _test_start_bonfire()
	await _test_title()
	_clean()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR))
	quit(1 if failures.size() > 0 else 0)


func _test_guard() -> void:
	# ヘッドレス (テスト、CI) では、既定でセーブを無効にする。誰かの本物のセーブを、テストが書き換えないように
	SaveGame.allow_headless = false
	check(DisplayServer.get_name() == "headless" and not SaveGame.enabled(), "ヘッドレスでは、既定でセーブが無効 (本物のセーブを書き換えない)")
	SaveGame.allow_headless = true
	check(SaveGame.enabled(), "明示すれば、ヘッドレスでも有効にできる (このテスト用)")


func _state(spawn: Variant = Vector3(1, 2, 3)) -> Dictionary:
	return {"spawn": SaveGame.encode_vector(spawn) if spawn is Vector3 else null, "time_total_hours": 31.5, "note": "メモ"}


func _test_round_trip() -> void:
	var id_a := SaveGame.world_id(SAMPLE)
	check(id_a.length() == 16 and id_a == SaveGame.world_id(SAMPLE), "世界の識別子は、データの中身から決まる (同じなら同じ、16 文字)")
	check(SaveGame.world_id(SAMPLE) != SaveGame.world_id("res://assets/sample_world.glb.import"), "中身が違えば、別の識別子 (データが変わったら、古いセーブは使わない)")
	check(SaveGame.path_for(SAMPLE).begins_with(TEST_DIR) and SaveGame.path_for(SAMPLE).ends_with("/game.json"), "セーブは、ゲームに 1 つのファイル")

	check(SaveGame.read(SAMPLE).status == "none" and not SaveGame.exists(SAMPLE), "セーブがなければ、なしと分かる")
	check(SaveGame.write(SAMPLE, _state()), "保存できる")
	check(SaveGame.exists(SAMPLE), "保存したら、あると分かる")
	var files := DirAccess.get_files_at(TEST_DIR)
	check(files.size() == 1 and not files[0].ends_with(".tmp"), "書き込み用の一時ファイルが残らない (途中で落ちても壊れないよう、一時ファイルへ書いてから付け替える)")

	var result := SaveGame.read(SAMPLE)
	check(result.status == "ok", "読み込める")
	var state: Dictionary = result.state
	check(state.version == SaveGame.VERSION and state.world_id == id_a, "バージョンと世界の識別子が入る")
	check(SaveGame.decode_vector(state.spawn) == Vector3(1, 2, 3), "位置が、そのまま戻る")
	check(is_equal_approx(state.time_total_hours, 31.5) and state.note == "メモ", "ほかの項目 (時刻、日本語の文字) も、そのまま戻る")
	check(state.saved_at is String and not (state.saved_at as String).is_empty(), "保存した日時が入る")

	# 上書きできる
	SaveGame.write(SAMPLE, _state(Vector3(9, 9, 9)))
	check(SaveGame.decode_vector(SaveGame.read(SAMPLE).state.spawn) == Vector3(9, 9, 9), "上書きできる")
	check(DirAccess.get_files_at(TEST_DIR).size() == 1, "上書きしても、ファイルは 1 つ")

	# 位置の検証
	check(SaveGame.decode_vector([1, 2]) == null and SaveGame.decode_vector("x") == null and SaveGame.decode_vector([1, 2, "a"]) == null, "位置が不正なら、無視する")
	check(SaveGame.decode_vector([1.0, 2.0, NAN]) == null and SaveGame.decode_vector([1e30, 0, 0]) == null, "位置が NaN や、桁外れの大きさなら、無視する")

	SaveGame.delete(SAMPLE)
	check(not SaveGame.exists(SAMPLE), "消せる")


# 世界の名前 (.json の world_id) があれば、データの中身が変わっても、セーブの鍵は変わらない
func _test_named_world() -> void:
	var dir := TEST_DIR + "/named"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var world := dir + "/world.glb"
	var sidecar := dir + "/world.json"
	var f := FileAccess.open(world, FileAccess.WRITE)
	f.store_string("中身 1")
	f.close()
	f = FileAccess.open(sidecar, FileAccess.WRITE)
	f.store_string(JSON.stringify({"world_id": "08OF3006-a1b2c3d4"}))
	f.close()

	check(SaveGame.world_id(world) == "08OF3006-a1b2c3d4", "世界の名前があれば、それが識別子になる")
	check(SaveGame.write(world, _state()), "名前のある世界を保存できる")
	f = FileAccess.open(world, FileAccess.WRITE)
	f.store_string("中身 2 (作り直した)")
	f.close()
	check(SaveGame.read(world).status == "ok", "データを作り直しても (中身が変わっても)、名前が同じなら、セーブが続く")

	for bad in ["../evil", ".hidden", "a/b", "", 5, "x".repeat(65), "abc\n"]:
		f = FileAccess.open(sidecar, FileAccess.WRITE)
		f.store_string(JSON.stringify({"world_id": bad}))
		f.close()
		check(WorldLoader.world_id_for(world).is_empty(), "使えない名前は無視する: %s" % str(bad))
		check(SaveGame.world_id(world).length() == 16, "使えない名前の時は、中身から決めた識別子に戻る: %s" % str(bad))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar))
	check(SaveGame.world_id(world).length() == 16, ".json がなければ、中身から決める (古い世界は今まで通り)")
	check(SaveGame.read(world).status == "none", "名前が外れたら、別の世界として扱う (名前のあるセーブは使わない)")
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	_clean()


# エリアが増えても、セーブは 1 つ。位置などはエリアごと、時刻はゲーム全体
func _test_areas() -> void:
	var other := "res://assets/sample_world.glb.import"  # 別の世界として扱う (中身が違うので、識別子も違う)
	SaveGame.delete()
	var first := _state(Vector3(1, 0, 0))
	first.time_total_hours = 10.0
	var second := _state(Vector3(2, 0, 0))
	second.time_total_hours = 20.0
	check(SaveGame.write(SAMPLE, first) and SaveGame.write(other, second), "2 つの世界を、続けて保存できる")
	check(DirAccess.get_files_at(TEST_DIR).size() == 1, "世界が 2 つでも、セーブのファイルは 1 つ")
	check(SaveGame.decode_vector(SaveGame.read(SAMPLE).state.spawn) == Vector3(1, 0, 0), "1 つ目の世界の位置は、2 つ目を保存しても、そのまま")
	check(SaveGame.decode_vector(SaveGame.read(other).state.spawn) == Vector3(2, 0, 0), "2 つ目の世界の位置も、戻る")
	check(is_equal_approx(SaveGame.read(SAMPLE).state.time_total_hours, 20.0), "時刻は、ゲーム全体で 1 つ (最後に保存した値が、どの世界でも読める)")
	SaveGame.delete(SAMPLE)
	check(SaveGame.read(SAMPLE).status == "none" and SaveGame.read(other).status == "none", "「はじめから」は、どの世界の記録も消す")

	# 初めて訪れるエリアでも、ゲーム全体の時刻は続く (記録は、なし)
	SaveGame.write(SAMPLE, first)
	var visit := SaveGame.read(other)
	check(visit.status == "none" and is_equal_approx(visit.game.time_total_hours, 10.0), "初めて訪れるエリアは、記録なし。でも、ゲーム全体の時刻は渡される")
	SaveGame.delete()

	# 世界の名前が "game" でも、セーブのファイルと取り違えない
	var dir := TEST_DIR + "/game_named"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var world := dir + "/world.glb"
	var f := FileAccess.open(world, FileAccess.WRITE)
	f.store_string("中身")
	f.close()
	f = FileAccess.open(dir + "/world.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"world_id": "game"}))
	f.close()
	check(SaveGame.write(world, _state()) and SaveGame.read(world).status == "ok", "世界の名前が game でも、保存して読める")
	check(FileAccess.file_exists(SaveGame.path_for(world)) and not FileAccess.file_exists(SaveGame.path_for(world) + ".v1"), "世界の名前が game でも、セーブのファイルを、取り込み済みの印に変えない")
	SaveGame.delete()
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


# 新しいバージョンのセーブは、delete (はじめから) では消えない。テストの後始末は、直接消す
func _remove_game_file() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGame.path_for()))


func _is_v1_file(path: String) -> bool:
	var json := JSON.new()
	return json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary and int(json.data.get("version", 0)) == 1


func _write_legacy(id: String, extra: Dictionary = {}, world: String = "") -> String:
	var legacy := {"version": 1, "world_id": world if not world.is_empty() else id, "saved_at": "2026-11-22T07:42:00", "has_rested": true, "spawn": [5.0, 6.0, 7.0], "time_total_hours": 8.5, "reveal_png": "AAAA"}
	legacy.merge(extra, true)
	var path := "%s/%s.json" % [TEST_DIR, id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(legacy))
	f.close()
	return path


# バージョン 1 (世界ごとに別のファイル) のセーブを、自動で取り込む。元は消さずに残す
func _test_legacy_import() -> void:
	SaveGame.delete()
	var id := SaveGame.world_id(SAMPLE)
	var legacy := _write_legacy(id)
	var result := SaveGame.read(SAMPLE)
	check(result.status == "ok" and SaveGame.decode_vector(result.state.spawn) == Vector3(5, 6, 7), "古い (バージョン 1) セーブを、読める")
	check(is_equal_approx(result.state.time_total_hours, 8.5) and result.state.reveal_png == "AAAA" and result.state.version == SaveGame.VERSION, "古いセーブの時刻や地図も、取り込まれる (バージョンは新しいもの)")
	check(not FileAccess.file_exists(legacy) and FileAccess.file_exists(legacy + ".v1"), "取り込んだ元のファイルは、消さずに .v1 として残る")
	check(FileAccess.file_exists(SaveGame.path_for(SAMPLE)), "取り込むと、新しいセーブのファイルができる")
	check(SaveGame.read(SAMPLE).status == "ok", "取り込んだあとも、読める (取り込み直さない)")

	# 取り込みの書き込みに失敗した (ディスクの空きがない時など): 元は残し、中身は、メモリ上で使う (進行を、失わない)
	SaveGame.delete()
	legacy = _write_legacy(id)
	SaveGame.fail_writes = true
	var offline := SaveGame.read(SAMPLE)
	SaveGame.fail_writes = false
	check(offline.status == "ok" and SaveGame.decode_vector(offline.state.spawn) == Vector3(5, 6, 7) and is_equal_approx(offline.state.time_total_hours, 8.5), "取り込めなくても、古いセーブの中身を、そのまま使える")
	check(FileAccess.file_exists(legacy) and not FileAccess.file_exists(SaveGame.path_for(SAMPLE)), "取り込めなかった元のファイルは、そのまま残る")
	check(SaveGame.write(SAMPLE, offline.state), "そのあと、保存できるようになったら、復元した状態を、保存できる")
	check(SaveGame.decode_vector(SaveGame.read(SAMPLE).state.spawn) == Vector3(5, 6, 7), "保存した状態は、古いセーブの進行を含む (取り込み直さなくても、失われない)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
	SaveGame.delete()
	legacy = _write_legacy(id)
	SaveGame.read(SAMPLE)  # 次の確認のために、いつも通りに取り込む

	# 「はじめから」のあとに、古いセーブが、よみがえらない
	SaveGame.delete(SAMPLE)
	check(SaveGame.read(SAMPLE).status == "none", "「はじめから」のあと、古いセーブは、取り込み直されない")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy + ".v1"))

	# すでに新しい記録があれば、古いもので上書きしない
	SaveGame.write(SAMPLE, _state(Vector3(9, 9, 9)))
	legacy = _write_legacy(id)
	check(SaveGame.decode_vector(SaveGame.read(SAMPLE).state.spawn) == Vector3(9, 9, 9), "新しい記録がある世界は、古いセーブで上書きしない")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy))
	SaveGame.delete()

	# 使えない古いセーブ (中の識別子が合わない、バージョンが違う) は、取り込まず、そのまま置く
	var bad_world := _write_legacy(id, {}, "0000000000000000")
	var bad_version := FileAccess.get_file_as_string(bad_world)
	check(SaveGame.read(SAMPLE).status == "none" and FileAccess.get_file_as_string(bad_world) == bad_version, "識別子が合わない古いセーブは、取り込まず、そのまま置く")
	var odd_version := _write_legacy(id, {"version": 7})
	check(SaveGame.read(SAMPLE).status == "none" and FileAccess.file_exists(odd_version), "バージョンが違う古いセーブは、取り込まず、そのまま置く")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(odd_version))

	# 新しいバージョンのセーブがある時は、古いセーブを取り込まない (新しいセーブを壊さない)
	var game := SaveGame.path_for(SAMPLE)
	var f := FileAccess.open(game, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": SaveGame.VERSION + 1, "areas": {}}))
	f.close()
	var future := FileAccess.get_file_as_string(game)
	var legacy2 := _write_legacy(id)
	check(SaveGame.read(SAMPLE).status == "newer" and FileAccess.get_file_as_string(game) == future and FileAccess.file_exists(legacy2), "新しいバージョンのセーブがあれば、古いセーブを取り込まず、どちらも残す")
	SaveGame.delete(SAMPLE)
	check(FileAccess.get_file_as_string(game) == future and FileAccess.file_exists(legacy2), "「はじめから」でも、新しいバージョンのセーブは、消さない (古いセーブも、そのまま)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy2))
	_remove_game_file()

	# 「はじめから」: まだ取り込んでいない古いセーブ (別の世界のものも、同じ世界の 2 つ目の候補も) も、取り込まれなくなる (消さずに .v1)
	var spare := _write_legacy("1111111111111111")
	var twin := _write_legacy(SaveGame.content_id(SAMPLE) if SaveGame.world_id(SAMPLE) != SaveGame.content_id(SAMPLE) else "2222222222222222")
	var mine := _write_legacy(id)
	SaveGame.read(SAMPLE)  # 自分のものを取り込む
	SaveGame.delete(SAMPLE)
	check(SaveGame.read(SAMPLE).status == "none" and not FileAccess.file_exists(SaveGame.path_for(SAMPLE)), "「はじめから」のあと、取り込み済みでない古いセーブも、よみがえらない")
	check(FileAccess.file_exists(spare + ".v1") and not FileAccess.file_exists(spare), "取り込んでいない古いセーブは、消さずに .v1 になる (ほかの世界のものも)")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(spare + ".v1"))
	for leftover: String in [twin, twin + ".v1", mine + ".v1"]:
		if FileAccess.file_exists(leftover):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))

	# 世界の名前が game だった、バージョン 1 のセーブ (ファイル名が、新しいセーブと同じ game.json) も、取り込む
	var game_world_dir := TEST_DIR + "/game_v1"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(game_world_dir))
	var game_world := game_world_dir + "/world.glb"
	f = FileAccess.open(game_world, FileAccess.WRITE)
	f.store_string("中身")
	f.close()
	f = FileAccess.open(game_world_dir + "/world.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"world_id": "game"}))
	f.close()
	var game_file := _write_legacy("game")
	# 新しい形に直せなかった (ディスクの空きがない時など): 退けず、そのまま残して、次に、もう一度試す
	SaveGame.fail_writes = true
	var stuck := SaveGame.read(game_world)
	var stuck_write := SaveGame.write(game_world, _state())
	SaveGame.fail_writes = false
	check(stuck.status == "none" and FileAccess.file_exists(game_file) and not FileAccess.file_exists(game_file + ".bad"), "直せなかった古いセーブ (game.json) は、退けず、そのまま残す")
	check(not stuck_write and _is_v1_file(game_file), "直せなかった間は、保存もしない (古いセーブを、上書きしない)")
	var other_world := SaveGame.read(SAMPLE)  # 別の世界を先に読んでも、game.json を壊したり、退けたりしない
	check(other_world.status == "none" and not FileAccess.file_exists(SaveGame.path_for(SAMPLE) + ".bad"), "世界の名前が game だった古いセーブは、別の世界を読んでも、退けられない")
	var game_v1 := SaveGame.read(game_world)
	check(game_v1.status == "ok" and SaveGame.decode_vector(game_v1.state.spawn) == Vector3(5, 6, 7) and FileAccess.file_exists(SaveGame.path_for(SAMPLE) + ".v1"), "世界の名前が game だった古いセーブも、取り込まれる (元は game.json.v1 に残る)")
	SaveGame.delete()
	for leftover: String in [SaveGame.path_for(SAMPLE) + ".v1", game_world_dir + "/world.glb", game_world_dir + "/world.json"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(game_world_dir))

	# 世界の名前を付ける前 (中身から決めた識別子) のセーブも、名前のある世界の記録として取り込む
	var dir := TEST_DIR + "/renamed"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var world := dir + "/world.glb"
	f = FileAccess.open(world, FileAccess.WRITE)
	f.store_string("中身")
	f.close()
	f = FileAccess.open(dir + "/world.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"world_id": "renamed-test"}))
	f.close()
	var content := SaveGame.content_id(world)
	var legacy3 := _write_legacy(content)
	var renamed := SaveGame.read(world)
	check(renamed.status == "ok" and renamed.state.world_id == "renamed-test" and FileAccess.file_exists(legacy3 + ".v1"), "名前を付ける前の (中身から決めた識別子の) セーブも、名前のある世界の記録として取り込む")
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	for file in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR + "/" + file))


func _test_write_failure() -> void:
	# 保存先に作れない (途中の名前が、フォルダではなくファイル) と、書けずに、false を返す。止まらない
	var blocker := TEST_DIR + "/blocker"
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	file.store_string("ファイル")
	file.close()
	var original := SaveGame.directory
	SaveGame.directory = blocker + "/sub"
	check(not SaveGame.write(SAMPLE, _state()), "保存先を作れない時は、保存できず、false を返す (止まらない)")
	SaveGame.directory = original
	DirAccess.remove_absolute(ProjectSettings.globalize_path(blocker))

	# 書き込みの結果は、確かめてから付け替える。確かめる部分 (_store) が、失敗を false で返すこと
	check(SaveGame._store(TEST_DIR + "/ok.tmp", "中身"), "書き込みが成功すれば、true")
	check(FileAccess.get_file_as_string(TEST_DIR + "/ok.tmp") == "中身", "書き込んだ中身が、そのまま入る")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_DIR + "/ok.tmp"))
	check(not SaveGame._store(TEST_DIR + "/no_such_dir/x.tmp", "中身"), "書き込めない場所では、false を返す")

	# 既存のセーブがあるところへ、書き込みに失敗しても、既存のセーブは、そのまま残る
	SaveGame.write(SAMPLE, _state(Vector3(7, 7, 7)))
	var before := FileAccess.get_file_as_string(SaveGame.path_for(SAMPLE))
	SaveGame.fail_writes = true  # 書き込みの失敗を再現する (テスト用)
	check(not SaveGame.write(SAMPLE, _state(Vector3(8, 8, 8))), "書き込みに失敗したら、保存できず、false を返す")
	SaveGame.fail_writes = false
	check(FileAccess.get_file_as_string(SaveGame.path_for(SAMPLE)) == before, "書き込みに失敗しても、既存のセーブは、そのまま残る (不完全なファイルで置き換えない)")
	check(not FileAccess.file_exists(SaveGame.path_for(SAMPLE) + ".tmp"), "書き込みに失敗しても、一時ファイルが残らない")
	check(SaveGame.read(SAMPLE).status == "ok", "失敗のあとも、前のセーブを読める")
	SaveGame.delete(SAMPLE)


func _test_broken_and_versions() -> void:
	var path := SaveGame.path_for(SAMPLE)

	# 壊れたセーブ: 止まらず、「壊れている」と返す。消さずに、別の名前で残す
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("これは JSON ではありません {{{")
	file.close()
	var result := SaveGame.read(SAMPLE)
	check(result.status == "invalid" and result.state.is_empty(), "壊れたセーブは、止まらず「壊れている」と返す")
	check(not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bad"), "壊れたセーブは、消さずに .bad として残す")
	check(SaveGame.read(SAMPLE).status == "none", "壊れたセーブを退けたあとは、セーブなしとして扱える")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bad"))

	# JSON だが、期待した形ではない
	for body in ["[1, 2, 3]", "\"文字\"", "{\"version\": \"1\"}", "{\"version\": 0}", "{\"version\": 1.5}", "{}"]:
		file = FileAccess.open(path, FileAccess.WRITE)
		file.store_string(body)
		file.close()
		check(SaveGame.read(SAMPLE).status == "invalid", "期待した形でない JSON は、壊れたセーブとして扱う (%s)" % body)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bad"))

	# 識別子が合わない (別の世界のセーブを、ファイル名だけ変えて置いた)
	SaveGame.write(SAMPLE, _state())
	var text := FileAccess.get_file_as_string(path).replace(SaveGame.world_id(SAMPLE), "0000000000000000")  # 別の世界の記録に見せる
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	check(SaveGame.read(SAMPLE).status == "none" and FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bad"), "別の世界の記録だけがあるセーブは、この世界の記録なしとして扱う (退けない)")

	# 新しいバージョンのセーブ: 読まず、上書きもしない (古いゲームで開いて、壊さないため)
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": SaveGame.VERSION + 1, "world_id": SaveGame.world_id(SAMPLE), "future": "未来の項目"}))
	file.close()
	var before := FileAccess.get_file_as_string(path)
	result = SaveGame.read(SAMPLE)
	check(result.status == "newer" and result.state.is_empty(), "新しいバージョンのセーブは、「新しい」と返して、中身は使わない")
	check(not SaveGame.write(SAMPLE, _state()), "新しいバージョンのセーブは、上書きしない (保存を断る)")
	check(FileAccess.get_file_as_string(path) == before and not FileAccess.file_exists(path + ".bad"), "新しいバージョンのセーブは、そのまま残る (壊したり、退けたりしない)")
	_remove_game_file()


func _test_reveal_png() -> void:
	var map := RevealMap.new(AABB(Vector3(0, 0, 0), Vector3(100, 10, 60)), 0.5)
	map.paint(Vector3(50, 0, 30), 10.0)
	map.paint(Vector3(10, 0, 10), 6.0)
	var bytes := map.to_png()
	check(bytes.size() > 0 and bytes.size() < map.width() * map.height(), "地図は、PNG に圧縮できる (%d バイト、元は %d)" % [bytes.size(), map.width() * map.height()])

	var restored := RevealMap.new(AABB(Vector3(0, 0, 0), Vector3(100, 10, 60)), 0.5)
	check(restored.load_png(bytes), "PNG から地図を戻せる")
	var same := true
	for point in [Vector3(50, 0, 30), Vector3(58, 0, 30), Vector3(10, 0, 10), Vector3(90, 0, 50), Vector3(0, 0, 0)]:
		same = same and is_equal_approx(restored.sample(point), map.sample(point))
	check(same and is_equal_approx(restored.coverage(), map.coverage()), "戻した地図は、元と同じ (確かめた所、縁のなめらかさ、割合)")

	# 大きさが違う地図 (世界が変わった) は、受け付けない
	var other := RevealMap.new(AABB(Vector3(0, 0, 0), Vector3(50, 10, 30)), 0.5)
	check(not other.load_png(bytes) and other.coverage() == 0.0, "大きさが違う地図は、受け付けず、地図は変わらない")
	check(not restored.load_png(PackedByteArray([1, 2, 3])) and not restored.load_png(PackedByteArray()), "壊れた PNG は、受け付けない")
	check(is_equal_approx(restored.coverage(), map.coverage()), "壊れた PNG を渡しても、地図は元のまま")


func _test_time_restore() -> void:
	var settings := GameSettings.new()
	settings.time_mode = "accelerated"
	var time := TimeOfDay.new(settings)
	time.restore(50.25)
	check(is_equal_approx(time.total_hours, 50.25) and is_equal_approx(time.hour, 2.25), "1 日を短くする方式では、保存した時刻に戻せる (通しの時間と、時刻)")
	var fixed := GameSettings.new()
	fixed.time_mode = "fixed"
	fixed.fixed_hour = 12.0
	var fixed_time := TimeOfDay.new(fixed)
	fixed_time.restore(50.25)
	check(is_equal_approx(fixed_time.hour, 12.0), "時刻を止める方式では、保存した時刻に動かされない")
	var real := GameSettings.new()
	real.time_mode = "realtime"
	var real_time := TimeOfDay.new(real)
	var before := real_time.total_hours
	real_time.restore(1.0)
	check(is_equal_approx(real_time.total_hours, before), "実時間の方式では、保存した時刻に動かされない (パソコンの時刻が正)")
	time.restore(NAN)
	time.restore(INF)
	check(is_equal_approx(time.total_hours, 50.25), "NaN や無限大の時刻は、受け付けない")


func _start_world(save_enabled: bool = true) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.time_mode = "accelerated"
	settings.start_hour = 7.0
	settings.day_length_minutes = 60.0
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = SAMPLE
	scene.get_node("World").save_enabled = save_enabled
	root.add_child(scene)
	return scene


func _test_game() -> void:
	SaveGame.delete(SAMPLE)

	# セーブがなければ、普通に始まる
	var scene := _start_world()
	for i in 40:
		await physics_frame
	var player: CharacterBody3D = scene.get_node("Player")
	var start_position: Vector3 = player.global_position
	check(not SaveGame.exists(SAMPLE), "休むまでは、セーブしない")
	check(not player.has_rested, "最初は、休んでいない")

	# 篝火で休むと、セーブされる
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	scene.add_child(fire)
	fire.global_position = player.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	var rested_positions: Array[Vector3] = []
	player.rested.connect(func(position: Vector3) -> void: rested_positions.append(position))
	# 休んだ時の順序: 点の表現が、周囲を確かめた所にしてから、「休んだ」が知らされる (その時にセーブされる)。
	# 逆だと、休んで確かめた範囲が、セーブに入らない
	var order := Recorder.new()
	order.add_to_group("point_world")
	scene.add_child(order)
	player.rested.connect(func(_position: Vector3) -> void: order.events.append("rested"))
	player.rest()
	check(order.events == ["rest", "rested"], "休むと、先に周囲が確かめた所になり、そのあとで「休んだ」と知らされる (順序: %s)" % [order.events])
	order.remove_from_group("point_world")
	check(rested_positions.size() == 1 and rested_positions[0].is_equal_approx(fire.global_position), "休むと、Player が「休んだ」と知らせる (篝火の位置つき)")
	check(player.has_rested, "休んだら、休んだことを覚える")
	check(SaveGame.exists(SAMPLE), "篝火で休むと、セーブされる")
	var saved: Dictionary = SaveGame.read(SAMPLE).state
	check(SaveGame.decode_vector(saved.spawn).is_equal_approx(fire.global_position + Vector3(0.0, 0.05, 1.5)), "最後に休んだ篝火 (復帰する位置) が保存される")
	check(saved.time_total_hours is float and saved.time_total_hours >= 7.0, "時刻が保存される (%.2f)" % saved.time_total_hours)
	check(saved.reveal_png is String and not (saved.reveal_png as String).is_empty(), "確かめた所の地図が保存される")
	var point_world: PointWorld = scene.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var painted := player.global_position + Vector3(3.0, 0.0, 3.0)
	point_world.reveal_at(painted, 4.0)

	# 閉じる時にも、セーブされる (確かめた所を、休まずに閉じても残す)
	scene.get_node("World").save_now()
	check(SaveGame.read(SAMPLE).status == "ok", "ゲームを閉じる時にも保存できる")
	scene.get_node("World")._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	scene.queue_free()
	await process_frame
	await process_frame

	# 次に始める時: 保存した場所から、保存した時刻と、確かめた所で続く
	var second := _start_world()
	for i in 40:
		await physics_frame
	var player2: CharacterBody3D = second.get_node("Player")
	var spawn: Vector3 = SaveGame.decode_vector(saved.spawn)
	var horizontal := Vector2(player2.global_position.x - spawn.x, player2.global_position.z - spawn.z).length()
	check(horizontal < 0.5, "つづきから: 最後に休んだ篝火から始まる (水平の距離 %.2f)" % horizontal)
	check(player2.spawn_position.is_equal_approx(spawn) and player2.has_rested, "つづきから: 復帰する位置が戻る")
	var point_world2: PointWorld = second.get_node("World").find_children("*", "PointWorld", false, false)[0]
	check(point_world2.reveal.sample(painted) > 0.5, "つづきから: 確かめた所が戻る")
	var second_time: TimeOfDay = second.get_node("DayNight").time
	check(second_time.total_hours >= saved.time_total_hours - 0.001, "つづきから: 時刻が戻る (%.2f → %.2f)" % [saved.time_total_hours, second_time.total_hours])
	check(point_world2.prev_image.get_pixelv(point_world2.reveal.pixel_of(painted)).r > 0.5, "つづきから: 波の前の地図も、戻した地図に合っている (最初の波で、消えて見えない)")
	second.queue_free()
	await process_frame

	# セーブなし (設定や引数で切った時) は、書かない・読まない
	SaveGame.delete(SAMPLE)
	var off := _start_world(false)
	for i in 40:
		await physics_frame
	var fire2: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	off.add_child(fire2)
	var p3: CharacterBody3D = off.get_node("Player")
	fire2.global_position = p3.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	p3.rest()
	check(not SaveGame.exists(SAMPLE), "セーブを切っていれば、休んでも保存しない")
	off.queue_free()
	await process_frame

	# 新しいバージョンのセーブがあれば、読まず、書かない (そのまま残す)
	var path := SaveGame.path_for(SAMPLE)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": SaveGame.VERSION + 5, "world_id": SaveGame.world_id(SAMPLE)}))
	file.close()
	var future := FileAccess.get_file_as_string(path)
	var newer := _start_world()
	for i in 40:
		await physics_frame
	var p4: CharacterBody3D = newer.get_node("Player")
	var fire3: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	newer.add_child(fire3)
	fire3.global_position = p4.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	p4.rest()
	newer.get_node("World")._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(FileAccess.get_file_as_string(path) == future, "新しいバージョンのセーブは、休んでも、閉じても、上書きされない")
	check(p4.has_rested and not newer.get_node("World").find_children("*", "PointWorld", false, false).is_empty(), "新しいバージョンのセーブでも、ゲームは普通に遊べる")
	newer.queue_free()
	await process_frame
	_remove_game_file()


# 初めて訪れるエリアでも、ゲーム全体の時刻から始まる (別のエリアで進めた時刻が、巻き戻らない)
func _test_time_for_new_area() -> void:
	SaveGame.delete()
	var state := _state()
	state.time_total_hours = 40.0
	SaveGame.write("res://assets/sample_world.glb.import", state)  # 別のエリアの記録と、ゲーム全体の時刻
	var scene := _start_world()
	for i in 20:
		await physics_frame
	var time: TimeOfDay = scene.get_node("DayNight").time
	check(time.total_hours >= 40.0, "初めて訪れるエリアでも、時刻は続く (%.2f 時間)" % time.total_hours)
	check(not scene.get_node("Player").has_rested, "記録のないエリアは、いつもの始まり方")
	scene.queue_free()
	await process_frame
	SaveGame.delete()


func _write_frame(sidecar: String, origin: Array) -> void:
	var f := FileAccess.open(sidecar, FileAccess.WRITE)
	f.store_string(JSON.stringify({"world_id": "frame-test", "origin": origin}))
	f.close()


func _start_world_at(path: String) -> Node:
	var scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	scene.get_node("DayNight").settings = settings
	scene.get_node("World").world_path = path
	root.add_child(scene)
	return scene


# 世界を作り直して、原点が動いた時: 標高が動けば、保存した位置も同じだけ動き (地下に出ない)、
# 水平が動けば、位置を直した上で、ずれて重なる確かめた所の地図は使わない
func _test_rebuilt_world() -> void:
	var dir := TEST_DIR + "/frame"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var world := dir + "/world.glb"
	var sidecar := dir + "/world.json"
	var f := FileAccess.open(world, FileAccess.WRITE)
	f.store_buffer(FileAccess.get_file_as_bytes(SAMPLE))
	f.close()
	_write_frame(sidecar, [1000.0, 2000.0, 150.0])
	SaveGame.delete(world)

	var scene := _start_world_at(world)
	for i in 40:
		await physics_frame
	var player: CharacterBody3D = scene.get_node("Player")
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	scene.add_child(fire)
	fire.global_position = player.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	player.rest()
	var point_world: PointWorld = scene.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var painted: Vector3 = fire.global_position
	point_world.reveal_at(painted, 4.0)
	scene.get_node("World").save_now()
	var saved: Dictionary = SaveGame.read(world).state
	var spawn: Vector3 = SaveGame.decode_vector(saved.spawn)
	check(saved.world_id == "frame-test" and SaveGame.decode_vector(saved.origin).is_equal_approx(Vector3(1000, 2000, 150)), "名前のある世界のセーブに、原点が入る")
	scene.queue_free()
	await process_frame
	await process_frame

	# 世界の形 (原点と範囲) が同じなら、そのまま信用する。位置が、(斜面などで) 近くの地面より低く見えても、捨てない
	var base: Dictionary = saved.duplicate()
	check(base.get("bounds") is Array and (base.bounds as Array).size() == 6, "セーブに、世界の範囲が入る")
	var low: Dictionary = base.duplicate()
	low.spawn = SaveGame.encode_vector(spawn + Vector3(0.0, -10.0, 0.0))
	SaveGame.write(world, low)
	var same_frame := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p1: CharacterBody3D = same_frame.get_node("Player")
	check(p1.has_rested and is_equal_approx(p1.spawn_position.y, spawn.y - 10.0), "世界の形が同じなら、位置を信用する (地面の検査をしない): %s" % [p1.spawn_position])
	var same_coverage: float = same_frame.get_node("World").find_children("*", "PointWorld", false, false)[0].reveal.coverage()
	same_frame.queue_free()
	await process_frame
	await process_frame

	# 範囲の高さだけが変わった (メッシュを粗くして、地面が上がった。原点は同じ): 作り直しと見なして、位置を確かめる。埋まっていれば使わない
	var coarse: Dictionary = low.duplicate()
	var box: Array = (base.bounds as Array).duplicate()
	box[4] = float(box[4]) + 10.0
	coarse.bounds = box
	SaveGame.write(world, coarse)
	var rebuilt := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p1b: CharacterBody3D = rebuilt.get_node("Player")
	check(not p1b.has_rested and p1b.spawn_position.y > -5.0, "範囲が変わった世界で、位置が地面の中なら、使わない: %s" % [p1b.spawn_position])
	rebuilt.queue_free()
	await process_frame
	await process_frame

	# 水平の範囲が変わった (切り出しを広げた。原点は同じ): 地図の座標系が変わるので、地図は使わない。位置は地面の上なら使う
	var wider: Dictionary = base.duplicate()
	var box2: Array = (base.bounds as Array).duplicate()
	box2[3] = float(box2[3]) + 50.0
	wider.bounds = box2
	SaveGame.write(world, wider)
	var broad := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p1c: CharacterBody3D = broad.get_node("Player")
	var wider_coverage: float = broad.get_node("World").find_children("*", "PointWorld", false, false)[0].reveal.coverage()
	check(p1c.has_rested and wider_coverage < same_coverage - 0.001, "水平の範囲が変わったら、地図は使わない (確かめた割合 %.3f → %.3f)" % [same_coverage, wider_coverage])
	broad.queue_free()
	await process_frame
	await process_frame
	SaveGame.write(world, base)

	# 標高の原点が 100 m 下がった (地形が、ゲームの中で 100 m 下がる): 保存した位置も 100 m 下がる (空中になり、落ちて着く)
	_write_frame(sidecar, [1000.0, 2000.0, 50.0])
	var raised := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p2: CharacterBody3D = raised.get_node("Player")
	check(is_equal_approx(p2.spawn_position.y, spawn.y + 100.0) and is_equal_approx(p2.spawn_position.x, spawn.x), "標高の原点が動いたら、保存した位置も、同じだけ動く: %s → %s" % [spawn, p2.spawn_position])
	var pw2: PointWorld = raised.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var pw2_coverage: float = pw2.reveal.coverage()
	check(pw2.reveal.sample(painted) > 0.5, "標高だけが動いた時は、確かめた所の地図を、そのまま使う")
	raised.queue_free()
	await process_frame
	await process_frame

	# 水平の原点が動いた (東へ 10 m): 位置を直し、地図は使わない
	_write_frame(sidecar, [1010.0, 2000.0, 150.0])
	var shifted := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p3: CharacterBody3D = shifted.get_node("Player")
	check(is_equal_approx(p3.spawn_position.x, spawn.x - 10.0) and is_equal_approx(p3.spawn_position.z, spawn.z), "水平の原点が動いたら、位置を直す: %s → %s" % [spawn, p3.spawn_position])
	var pw3: PointWorld = shifted.get_node("World").find_children("*", "PointWorld", false, false)[0]
	check(pw3.reveal.coverage() < pw2_coverage - 0.001, "水平が動いた時は、ずれて重なる地図を使わない (確かめた割合 %.3f → %.3f)" % [pw2_coverage, pw3.reveal.coverage()])
	shifted.queue_free()
	await process_frame

	# 作り直した世界の範囲の外へ出てしまう (切り出しが変わって、保存した篝火が、範囲の外になった):
	# その位置は使わず、いつもの始まり方にする (使うと、落ちて、同じ位置へ戻ることを繰り返す)
	_write_frame(sidecar, [5000.0, 2000.0, 150.0])
	var outside := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p4: CharacterBody3D = outside.get_node("Player")
	check(not p4.has_rested and p4.spawn_position.distance_to(spawn + Vector3(-4000.0, 0.0, 0.0)) > 1000.0, "範囲の外になる位置は使わず、いつもの始まり方にする: %s" % [p4.spawn_position])
	check(p4.spawn_position.y > -50.0 and absf(p4.spawn_position.x) < 1000.0, "いつもの始まりの位置は、世界の中にある")
	outside.queue_free()
	await process_frame

	# 地面の中になる (標高の原点が 100 m 上がって、地面が、保存した位置より、100 m 上がった): その位置は使わない。
	# メッシュを粗くした (--voxel を大きくした) 時のように、原点が同じで、地面だけが上がる場合も、同じ判定で防ぐ
	_write_frame(sidecar, [1000.0, 2000.0, 250.0])
	var buried := _start_world_at(world)
	for i in 40:
		await physics_frame
	var p5: CharacterBody3D = buried.get_node("Player")
	check(not p5.has_rested and p5.spawn_position.y > -50.0, "地面の中になる位置は使わず、いつもの始まり方にする: %s" % [p5.spawn_position])
	buried.queue_free()
	await process_frame

	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	_clean()


# 休んで保存に失敗したら、そのことが画面に出て、「基準点を確定しました」に上書きされず、読める時間、残る
func _test_failure_notice() -> void:
	SaveGame.delete(SAMPLE)
	var scene := _start_world()
	for i in 40:
		await physics_frame
	var player: CharacterBody3D = scene.get_node("Player")
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	scene.add_child(fire)
	fire.global_position = player.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	SaveGame.fail_writes = true
	player.rest()
	SaveGame.fail_writes = false
	check(player.message.visible and player.message.text == "セーブに失敗しました", "保存に失敗したら、その旨が画面に出る (「基準点を確定しました」に上書きされない: %s)" % player.message.text)
	await _seconds(player.NOTICE_SECONDS + 0.3)  # 休んだ知らせ (1.5 秒) が消える時間を過ぎても、失敗の知らせは残る
	check(player.message.visible and player.message.text == "セーブに失敗しました", "休んだ知らせが消える時間を過ぎても、保存の失敗は、読める時間、残る")
	await _seconds(2.0)
	check(not player.message.visible, "保存の失敗の知らせも、しばらくすると消える")

	# 成功した時は、普通に「基準点を確定しました」が出る
	player.rest()
	check(player.message.text == "基準点を確定しました", "保存に成功した時は、「基準点を確定しました」が出る")
	scene.queue_free()
	await process_frame
	SaveGame.delete(SAMPLE)


# 閉じる時に保存に失敗したら、そのまま閉じず、知らせて保留する。もう一度閉じれば、閉じられる
func _test_close_with_failed_save() -> void:
	SaveGame.delete(SAMPLE)
	var scene := _start_world()
	for i in 40:
		await physics_frame
	var world: Node = scene.get_node("World")
	var player: CharacterBody3D = scene.get_node("Player")
	var tree := scene.get_tree()
	check(tree.auto_accept_quit, "(前提) 普段は、閉じる操作で、そのまま終了する")

	# 保存に成功する時は、そのまま閉じる
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(tree.auto_accept_quit and SaveGame.exists(SAMPLE), "保存に成功すれば、そのまま閉じられる (終了を保留しない)")

	# 保存に失敗する時は、閉じるのを保留して、知らせる
	SaveGame.fail_writes = true
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(not tree.auto_accept_quit, "保存に失敗したら、閉じるのを保留する (知らせを読む前に、終了しない)")
	check(player.message.visible and "もう一度" in player.message.text, "保留の理由と、もう一度閉じると保存せずに終了することを、知らせる (%s)" % player.message.text)

	# もう一度閉じる: 保存できなくても、望むなら、閉じられる
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(tree.auto_accept_quit, "もう一度閉じれば、保存できなくても、終了できる (閉じられなくならない)")

	# 保留が解けたあと: また保存を試みる (今度は成功する)
	SaveGame.fail_writes = false
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(tree.auto_accept_quit, "保存できる状態に戻れば、また普通に閉じられる")

	# 保留したまま放っておいても、保留が解ける (終了できないまま、になる)
	SaveGame.fail_writes = true
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(not tree.auto_accept_quit, "(前提) もう一度、保留した")
	await _seconds(world.CLOSE_HOLD_SECONDS + 0.4)
	check(tree.auto_accept_quit, "保留は、しばらくすると解ける (閉じる操作が、効かなくなったままにならない)")
	SaveGame.fail_writes = false

	# 画面を閉じるように、この場面が消えても、終了の設定が、保留のまま残らない
	SaveGame.fail_writes = true
	world._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	SaveGame.fail_writes = false
	scene.queue_free()
	await process_frame
	await process_frame
	check(tree.auto_accept_quit, "場面が消えても、終了の設定が、保留のまま残らない")

	# セーブを切っている時は、保存しないので、そのまま閉じる
	var off := _start_world(false)
	for i in 20:
		await physics_frame
	off.get_node("World")._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(tree.auto_accept_quit, "セーブを切っていれば、そのまま閉じられる")
	off.queue_free()
	await process_frame
	SaveGame.delete(SAMPLE)


# 点の表現を切って遊んでも、保存済みの確かめた所の地図を失わない (戻した時に、また使える)
func _test_points_off_keeps_map() -> void:
	SaveGame.delete(SAMPLE)
	var first := _start_world()
	for i in 40:
		await physics_frame
	var player: CharacterBody3D = first.get_node("Player")
	var points: PointWorld = first.get_node("World").find_children("*", "PointWorld", false, false)[0]
	var painted := player.global_position + Vector3(4.0, 0.0, 4.0)
	points.reveal_at(painted, 3.0)
	check(first.get_node("World").save_now(), "(前提) 地図つきで保存できる")
	var saved_png: String = SaveGame.read(SAMPLE).state.reveal_png
	first.queue_free()
	await process_frame

	# 点の表現を切って始める。休んでも、閉じても、地図は保存に引き継がれる
	var off := _start_world()
	off.get_node("World").point_mode = "off"
	off.queue_free()
	await process_frame
	var off_scene: Node = load("res://scenes/world_local.tscn").instantiate()
	var settings := GameSettings.new()
	settings.weather_enabled = false
	off_scene.get_node("DayNight").settings = settings
	off_scene.get_node("World").world_path = SAMPLE
	off_scene.get_node("World").point_mode = "off"
	root.add_child(off_scene)
	for i in 40:
		await physics_frame
	var p2: CharacterBody3D = off_scene.get_node("Player")
	check(off_scene.get_node("World").find_children("*", "PointWorld", false, false).is_empty(), "(前提) 点の表現を切って始まった")
	var fire: Node3D = load("res://scenes/bonfire.tscn").instantiate()
	off_scene.add_child(fire)
	fire.global_position = p2.global_position + Vector3(1.0, 0.0, 0.0)
	for i in 5:
		await process_frame
	p2.rest()
	off_scene.get_node("World")._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var after: Dictionary = SaveGame.read(SAMPLE).state
	check(after.get("reveal_png") == saved_png, "点の表現を切っていても、休んだ・閉じた時に、保存済みの地図が、セーブに引き継がれる (失われない)")
	check(after.has("spawn"), "(ほかの項目は、普通に保存される)")
	off_scene.queue_free()
	await process_frame

	# 点の表現を戻すと、保存した地図が、そのまま使える
	var back := _start_world()
	for i in 40:
		await physics_frame
	var back_points: PointWorld = back.get_node("World").find_children("*", "PointWorld", false, false)[0]
	check(back_points.reveal.sample(painted) > 0.9, "点の表現を戻すと、前に確かめた所が、残っている")
	back.queue_free()
	await process_frame
	SaveGame.delete(SAMPLE)


# 最初の地点に、篝火が 1 つある。遊びの中で、休める (休むとセーブされ、落ちたらここへ戻る)
func _test_start_bonfire() -> void:
	SaveGame.delete(SAMPLE)
	var scene := _start_world()
	for i in 60:
		await physics_frame
	var player: CharacterBody3D = scene.get_node("Player")
	var fires := scene.get_tree().get_nodes_in_group("bonfire").filter(func(node: Node) -> bool: return scene.is_ancestor_of(node))
	check(fires.size() == 1, "世界に、最初の篝火が 1 つある")
	var fire: Node3D = fires[0]
	check(player.global_position.distance_to(fire.global_position) < player.REST_DISTANCE, "最初の篝火は、始めた場所のすぐそばにある (%.2f m)" % player.global_position.distance_to(fire.global_position))
	check(player.nearby_bonfire == fire and player.prompt.visible, "始めてすぐ、「休む」の案内が出る")
	player.rest()
	check(player.has_rested and SaveGame.exists(SAMPLE), "最初の篝火で休むと、休んだことになり、セーブされる")
	var spawn: Vector3 = SaveGame.decode_vector(SaveGame.read(SAMPLE).state.spawn)
	check(spawn.is_equal_approx(fire.rest_position()), "セーブされる復帰地点は、その篝火")
	scene.queue_free()
	await process_frame

	# 続きから始めると、篝火のそばから始まり、また休める
	var second := _start_world()
	for i in 60:
		await physics_frame
	var p2: CharacterBody3D = second.get_node("Player")
	check(p2.nearby_bonfire != null and p2.has_rested, "つづきから始めても、篝火のそばにいて、休んだ状態で続く")
	second.queue_free()
	await process_frame
	SaveGame.delete(SAMPLE)


func _test_title() -> void:
	SaveGame.delete(SAMPLE)
	var title: Node = load("res://scenes/title.tscn").instantiate()
	title.world_path = SAMPLE
	title.auto_change_scene = false
	root.add_child(title)
	await process_frame
	check(title.start_button.text == "はじめる" and not title.new_game_button.visible, "セーブがなければ、「はじめる」だけが出る")
	title.queue_free()
	await process_frame

	SaveGame.write(SAMPLE, _state())
	var with_save: Node = load("res://scenes/title.tscn").instantiate()
	with_save.world_path = SAMPLE
	with_save.auto_change_scene = false
	root.add_child(with_save)
	await process_frame
	check(with_save.start_button.text == "つづきから" and with_save.new_game_button.visible, "セーブがあれば、「つづきから」と「はじめから」が出る")
	check(with_save.start_button.has_focus(), "「つづきから」にフォーカスがある")

	var started: Array[String] = []
	with_save.start_requested.connect(func(path: String) -> void: started.append(path))
	with_save.start_button.pressed.emit()
	check(started == [SAMPLE] and SaveGame.exists(SAMPLE), "「つづきから」は、セーブを残したまま始まる")

	# 設定で、セーブを切っている時は、「つづきから」も「はじめから」も出さない (ゲームは、復元も保存もしないため)
	var disabled: Node = load("res://scenes/title.tscn").instantiate()
	disabled.world_path = SAMPLE
	disabled.auto_change_scene = false
	var off := GameSettings.new()
	off.save_enabled = false
	disabled.settings = off
	root.add_child(disabled)
	await process_frame
	check(disabled.start_button.text == "はじめる" and not disabled.new_game_button.visible, "セーブを切っていれば、セーブがあっても、「つづきから」「はじめから」は出ない")
	check(SaveGame.exists(SAMPLE), "セーブを切っていても、セーブは消されない (はじめから、が出ないので、消せない)")
	disabled.queue_free()
	await process_frame

	# 「はじめから」は、1 回目で確認を出し、2 回目でセーブを消して始まる (うっかり消さない)
	started.clear()
	with_save.new_game_button.pressed.emit()
	check(started.is_empty() and SaveGame.exists(SAMPLE), "「はじめから」を 1 回押しただけでは、消えない")
	check("もう一度" in with_save.new_game_button.text, "「はじめから」は、もう一度押す確認を出す (%s)" % with_save.new_game_button.text)
	with_save.new_game_button.pressed.emit()
	check(started == [SAMPLE] and not SaveGame.exists(SAMPLE), "もう一度押すと、セーブを消して始まる")
	with_save.queue_free()
	await process_frame
