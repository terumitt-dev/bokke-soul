class_name SaveGame
extends RefCounted
# セーブ。ゲームに 1 つのファイル (JSON) に、ゲームの続きの状態を保存する。中には、エリア (世界) ごとの記録が入る。
#
#   {"version": 2, "saved_at": ..., "time_total_hours": ..., "areas": {"<世界の識別子>": {位置、確かめた所、…}}}
#
#   - 時刻は、ゲーム全体のもの。位置や確かめた所は、エリアごとのもの。エリアが増えても、セーブは 1 つのまま
#   - バージョン付き。あとから項目を足しても、古いセーブを読めるようにする (_migrate)
#   - 世界の識別子は、データの隣の .json の world_id。なければ、世界のデータ (GLB) の中身から決める
#   - バージョン 1 (世界ごとに別のファイル <識別子>.json) のセーブは、その世界を読む時に、自動で取り込む。
#     取り込んだ元のファイルは、消さずに <識別子>.json.v1 として残す (取り込み直さないため。いつでも見直せる)
#   - 書き込みは、一時ファイルへ書いてから付け替える (途中で落ちても、セーブが壊れない)
#   - 壊れたセーブは、止まらず退ける。消さずに .bad として残す
#   - 新しいバージョンのセーブ (新しいゲームで作ったもの) は、読まず、上書きもしない
#   - ヘッドレス (テスト、CI) では、既定で無効。誰かの本物のセーブを、テストが書き換えないように

const VERSION := 2
const FILE_NAME := "game.json"
const LEGACY_VERSION := 1  # 世界ごとに別のファイルだった頃のバージョン
const GAME_KEYS := ["time_total_hours"]  # エリアに属さない (ゲーム全体の) 項目
const MAX_COORDINATE := 1.0e7  # 位置として受け付ける大きさ (m)

# 保存先。テストは、専用の場所に変える
static var directory := "user://saves"
# ヘッドレスでも有効にする (セーブのテスト用)
static var allow_headless := false
# 書き込みの途中で失敗する (ディスクの空きがない時など) ことを再現する (セーブのテスト用)
static var fail_writes := false


static func enabled() -> bool:
	return DisplayServer.get_name() != "headless" or allow_headless


# 世界の識別子。データの隣の .json に world_id があれば、それ (作り直しても、場所が同じなら変わらない)。
# なければ、世界のデータ (GLB) の中身から決めた 16 文字。データもなければ、場所の文字から決める
static func world_id(world_path: String) -> String:
	var named := WorldLoader.world_id_for(world_path)
	if not named.is_empty():
		return named
	return content_id(world_path)


# 世界のデータ (GLB) の中身から決めた識別子 (16 文字)。データがなければ、場所の文字から決める
static func content_id(world_path: String) -> String:
	var hash := FileAccess.get_sha256(world_path)
	if hash.is_empty():
		hash = world_path.sha256_text()
	return hash.substr(0, 16)


# セーブのファイル (ゲームに 1 つ)。world_path は、どの世界でも同じ場所を指す (呼び出しを変えずに済むよう、受け取る)
static func path_for(_world_path: String = "") -> String:
	return "%s/%s" % [directory, FILE_NAME]


static func exists(world_path: String) -> bool:
	return enabled() and FileAccess.file_exists(path_for(world_path))


# その世界 (エリア) の記録を保存する。state は、位置などの項目。ゲーム全体の項目 (時刻) も、ここで一緒に渡す。
# 新しいバージョンのセーブが、すでにあれば、上書きせず false を返す
static func write(world_path: String, state: Dictionary) -> bool:
	if not enabled():
		return false
	var path := path_for(world_path)
	if FileAccess.file_exists(path) and _stored_version(path) > VERSION:
		push_warning("新しいバージョンのセーブがあるので、上書きしません: " + path)
		return false

	if not _adopt_v1_game_file():
		push_warning("古いセーブ (game.json) を新しい形に直せなかったので、保存しません: " + path)
		return false
	var document := _load_document(world_path)
	var area := state.duplicate()
	for key: String in GAME_KEYS:
		if area.has(key):
			document[key] = area[key]
			area.erase(key)
	var areas: Dictionary = document.areas
	areas[world_id(world_path)] = area
	return _write_document(document)


# 文書 (ゲーム全体) を、ファイルへ書く。一時ファイルへ書いてから、付け替える
static func _write_document(document: Dictionary) -> bool:
	var path := path_for()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var full := document.duplicate()
	full["version"] = VERSION
	full["saved_at"] = Time.get_datetime_string_from_system(true)

	# 一時ファイルへ書いてから、付け替える。書いている途中で落ちても、いまのセーブは壊れない。
	# 書き込みが失敗したら (ディスクの空きがない時など)、いまのセーブは置き換えず、一時ファイルを消して false を返す
	var temp := path + ".tmp"
	if not _store(temp, JSON.stringify(full)):
		push_warning("セーブを書けませんでした: " + temp)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp))
		return false
	var temp_os := ProjectSettings.globalize_path(temp)
	var path_os := ProjectSettings.globalize_path(path)
	if DirAccess.rename_absolute(temp_os, path_os) != OK:
		# 付け替え先が、すでにあって失敗する環境がある。消してから、もう一度付け替える
		DirAccess.remove_absolute(path_os)
		if DirAccess.rename_absolute(temp_os, path_os) != OK:
			push_warning("セーブを付け替えられませんでした: " + path)
			return false
	return true


# 文字を、ファイルへ書く。書き込みと、書き出し (flush) の結果を確かめて、成功した時だけ true
static func _store(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	if fail_writes:
		file.store_string(text.substr(0, text.length() / 2))  # 途中までしか書けなかった、を再現する
		file.close()
		return false
	var written := file.store_string(text)
	file.flush()
	var ok := written and file.get_error() == OK
	file.close()
	return ok


# 読む。{"status": ..., "state": ...}。status は次のどれか:
#   none: セーブがない、または、この世界の記録がない / ok: 読めた / invalid: 壊れている (退けた) / newer: 新しいバージョンのセーブ (使わない)
# state は、その世界の記録に、ゲーム全体の項目 (時刻)、version、world_id、saved_at を足したもの。
# game は、ゲーム全体の項目 (時刻) だけ。この世界の記録がなくても (初めて訪れるエリアでも)、入る
static func read(world_path: String) -> Dictionary:
	var result := {"status": "none", "state": {}, "game": {}}
	if not enabled():
		return result
	if not _adopt_v1_game_file():
		return result  # 直せなかった。壊れたセーブとして退けず、そのまま残して、次に、もう一度試す
	_import_legacy(world_path)
	var path := path_for(world_path)
	if not FileAccess.file_exists(path):
		return result

	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return _reject(path, result)
	var document: Dictionary = json.data

	var version: Variant = document.get("version")
	if not _is_version(version):
		return _reject(path, result)
	if int(version) > VERSION:
		result.status = "newer"
		return result
	if not (document.get("areas") is Dictionary):
		return _reject(path, result)

	for key: String in GAME_KEYS:  # ゲーム全体の項目 (時刻) は、この世界の記録がなくても、渡す (初めて訪れるエリアでも、時刻は続く)
		if document.has(key):
			result.game[key] = document[key]
	var area: Variant = (document.areas as Dictionary).get(world_id(world_path))
	if not (area is Dictionary):
		return result  # このセーブに、この世界の記録はない (別の世界を遊んだ記録だけがある)

	var state: Dictionary = (area as Dictionary).duplicate()
	for key: String in GAME_KEYS:
		if document.has(key):
			state[key] = document[key]
	state["version"] = version
	state["world_id"] = world_id(world_path)
	state["saved_at"] = document.get("saved_at", "")
	result.status = "ok"
	result.state = _migrate(state)
	return result


# 「はじめから」: セーブを消す (ゲーム全体。どのエリアの記録も、時刻も消える)。
# まだ取り込んでいない古い (バージョン 1) セーブも、取り込まれないようにする (消さずに .v1 にする。消した進行が、よみがえらないように)。
# 新しいバージョンのセーブは、消さない
static func delete(world_path: String = "") -> void:
	if not enabled():
		return
	var path := path_for(world_path)
	if FileAccess.file_exists(path):
		if _stored_version(path) > VERSION:
			push_warning("新しいバージョンのセーブは、消しません: " + path)
			return
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for file in DirAccess.get_files_at(directory):
		var legacy := "%s/%s" % [directory, file]
		if file.ends_with(".json") and legacy != path_for() and _is_legacy_file(legacy):
			DirAccess.rename_absolute(ProjectSettings.globalize_path(legacy), ProjectSettings.globalize_path(legacy + ".v1"))


static func _is_legacy_file(path: String) -> bool:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return false
	var state: Dictionary = json.data
	return _is_version(state.get("version")) and int(state.version) == LEGACY_VERSION


# 世界の名前が "game" だった、バージョン 1 のセーブは、ファイル名が、新しいセーブ (game.json) と同じ。
# 中身で見分けて (バージョン 1 で、areas がない)、新しい形に直す。元は game.json.v1 として残す
# 直せた (直す必要がなかった) 時は true。直そうとして失敗した時は false (元の game.json は、そのまま残す。呼び出し側は、
# 読まず、書かず、退けない。次に、もう一度試す)
static func _adopt_v1_game_file() -> bool:
	var path := path_for()
	if not FileAccess.file_exists(path) or not _is_legacy_file(path):
		return true
	var imported := _read_legacy(path, "game")
	if imported.is_empty():
		return true  # バージョン 1 だが、世界の名前が game ではない。取り込めないので、壊れたセーブとして扱われる
	if DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(path + ".v1")) != OK:
		return false  # 元を残せないなら、触らない
	var document := {"areas": {}}
	for key: String in GAME_KEYS:
		if imported.has(key):
			document[key] = imported[key]
		imported.erase(key)
	(document.areas as Dictionary)["game"] = imported
	return _write_document(document)


# いまの文書を読む (なければ、空の文書)。読めない文書は、退けて、空の文書にする
static func _load_document(world_path: String) -> Dictionary:
	var empty := {"areas": {}}
	var path := path_for(world_path)
	if not FileAccess.file_exists(path):
		return empty
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		_reject(path, {})
		return empty
	var document: Dictionary = json.data
	if not _is_version(document.get("version")) or not (document.get("areas") is Dictionary):
		_reject(path, {})
		return empty
	return document


# バージョン 1 のセーブ (世界ごとに別のファイル) があれば、この世界の記録として取り込む。
# すでにこの世界の記録があれば、取り込まない (新しい記録を、古いもので上書きしない)
static func _import_legacy(world_path: String) -> void:
	var id := world_id(world_path)
	if _has_area(id) or (FileAccess.file_exists(path_for()) and _stored_version(path_for()) > VERSION):
		return  # すでに取り込んだ、または、新しいバージョンのセーブがある (上書きしない)
	var candidates := [id]
	var content := content_id(world_path)  # 世界の名前を付ける前の、データの中身から決めた識別子のセーブも探す
	if content != id:
		candidates.append(content)
	for candidate: String in candidates:
		var legacy := "%s/%s.json" % [directory, candidate]
		if legacy == path_for() or not FileAccess.file_exists(legacy):  # 世界の名前が "game" でも、新しいセーブと取り違えない
			continue
		var imported := _read_legacy(legacy, candidate)
		if imported.is_empty():
			continue
		var document := _load_document(world_path)
		var areas: Dictionary = document.areas
		for key: String in GAME_KEYS:
			if imported.has(key) and not document.has(key):
				document[key] = imported[key]
			imported.erase(key)
		areas[id] = imported
		if not _write_document(document):
			return  # 取り込めなかった。元のファイルは、そのままにしておく (次に、もう一度試す)
		DirAccess.rename_absolute(ProjectSettings.globalize_path(legacy), ProjectSettings.globalize_path(legacy + ".v1"))
		return


# セーブに、この世界の記録があるか (ファイルを退けたりはしない。壊れていれば、ない、と答える)
static func _has_area(id: String) -> bool:
	var path := path_for()
	if not FileAccess.file_exists(path):
		return false
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return false
	var areas: Variant = (json.data as Dictionary).get("areas")
	return areas is Dictionary and (areas as Dictionary).get(id) is Dictionary


# バージョン 1 のセーブを読む。使える時は、項目の辞書 (version、world_id、saved_at は除く)。使えなければ、空
static func _read_legacy(path: String, id: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return {}
	var state: Dictionary = json.data
	if not _is_version(state.get("version")) or int(state.version) != LEGACY_VERSION or state.get("world_id") != id:
		return {}
	var result := state.duplicate()
	for key: String in ["version", "world_id", "saved_at"]:
		result.erase(key)
	return result


# 位置 (Vector3) を、保存できる形 (配列) にする
static func encode_vector(vector: Vector3) -> Array:
	return [vector.x, vector.y, vector.z]


# 保存した位置を、Vector3 に戻す。不正 (形が違う、NaN、桁外れ) なら null
static func decode_vector(value: Variant) -> Variant:
	if not (value is Array) or (value as Array).size() != 3:
		return null
	for component: Variant in value:
		if not (component is float or component is int) or not is_finite(component) or absf(component) > MAX_COORDINATE:
			return null
	return Vector3(value[0], value[1], value[2])


static func encode_bytes(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes)


static func decode_bytes(text: Variant) -> PackedByteArray:
	if not (text is String) or (text as String).is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(text)


# 古いバージョンのセーブを、いまの形に直す。いまはバージョン 1 だけなので、何もしない。
# 項目を足す時は、ここに「バージョン n → n+1」の変換を足す
static func _migrate(state: Dictionary) -> Dictionary:
	return state


static func _is_version(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(value) and value >= 1 and value == floorf(value)


# 保存済みのファイルのバージョン (読めなければ 0)。上書きしてよいかの判断に使う
static func _stored_version(path: String) -> int:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return 0
	var version: Variant = (json.data as Dictionary).get("version")
	return int(version) if _is_version(version) else 0


# 壊れたセーブを退ける。消さずに、.bad として残す (中身を調べられるように)
static func _reject(path: String, result: Dictionary) -> Dictionary:
	push_warning("セーブが壊れています。退けて、新しく始めます: " + path)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(path + ".bad"))
	result.status = "invalid"
	return result
