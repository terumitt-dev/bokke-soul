class_name SaveGame
extends RefCounted
# セーブ。世界ごとに別のファイル (JSON) に、ゲームの続きの状態を保存する。
#
#   - バージョン付き。あとから項目を足しても、古いセーブを読めるようにする (_migrate)
#   - 世界の識別子は、世界のデータ (GLB) の中身から決める。データが変わったら、古いセーブは使わない
#   - 書き込みは、一時ファイルへ書いてから付け替える (途中で落ちても、セーブが壊れない)
#   - 壊れたセーブは、止まらず退ける。消さずに .bad として残す
#   - 新しいバージョンのセーブ (新しいゲームで作ったもの) は、読まず、上書きもしない
#   - ヘッドレス (テスト、CI) では、既定で無効。誰かの本物のセーブを、テストが書き換えないように

const VERSION := 1
const MAX_COORDINATE := 1.0e7  # 位置として受け付ける大きさ (m)

# 保存先。テストは、専用の場所に変える
static var directory := "user://saves"
# ヘッドレスでも有効にする (セーブのテスト用)
static var allow_headless := false
# 書き込みの途中で失敗する (ディスクの空きがない時など) ことを再現する (セーブのテスト用)
static var fail_writes := false


static func enabled() -> bool:
	return DisplayServer.get_name() != "headless" or allow_headless


# 世界の識別子 (16 文字)。世界のデータの中身から決める。データがなければ、場所の文字から決める
static func world_id(world_path: String) -> String:
	var hash := FileAccess.get_sha256(world_path)
	if hash.is_empty():
		hash = world_path.sha256_text()
	return hash.substr(0, 16)


static func path_for(world_path: String) -> String:
	return "%s/%s.json" % [directory, world_id(world_path)]


static func exists(world_path: String) -> bool:
	return enabled() and FileAccess.file_exists(path_for(world_path))


# 保存する。state に、version、world_id、saved_at を足して書く。
# 新しいバージョンのセーブが、すでにあれば、上書きせず false を返す
static func write(world_path: String, state: Dictionary) -> bool:
	if not enabled():
		return false
	var path := path_for(world_path)
	if FileAccess.file_exists(path) and _stored_version(path) > VERSION:
		push_warning("新しいバージョンのセーブがあるので、上書きしません: " + path)
		return false

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var full := state.duplicate()
	full["version"] = VERSION
	full["world_id"] = world_id(world_path)
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
#   none: セーブがない / ok: 読めた / invalid: 壊れている (退けた) / newer: 新しいバージョンのセーブ (使わない)
static func read(world_path: String) -> Dictionary:
	var result := {"status": "none", "state": {}}
	if not exists(world_path):
		return result
	var path := path_for(world_path)

	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not (json.data is Dictionary):
		return _reject(path, result)
	var state: Dictionary = json.data

	var version: Variant = state.get("version")
	if not _is_version(version):
		return _reject(path, result)
	if int(version) > VERSION:
		result.status = "newer"
		return result
	if state.get("world_id") != world_id(world_path):
		return _reject(path, result)

	result.status = "ok"
	result.state = _migrate(state)
	return result


static func delete(world_path: String) -> void:
	var path := path_for(world_path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


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
