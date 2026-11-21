extends SceneTree

# 実行: godot --headless --path game --script res://tests/title_test.gd
# タイトル画面 (表示、メニュー、クレジット、出典、書体) を確かめる

const TMP_CREDIT := "user://credit_test.json"

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _start(path: String) -> Node:
	var scene: Node = load("res://scenes/title.tscn").instantiate()
	scene.world_path = path
	scene.auto_change_scene = false
	root.add_child(scene)
	return scene


func _initialize() -> void:
	_test_loader()
	_test_font()
	await _test_title()
	await _test_fallback()
	quit(1 if failures.size() > 0 else 0)


func _write_credit(text: String) -> void:
	var file := FileAccess.open(TMP_CREDIT, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _test_loader() -> void:
	check(WorldLoader.resolve_path("/a/b.glb") == "/a/b.glb", "指定した世界の場所が、いちばん優先される")
	WorldLoader.selected_path = ""
	check(WorldLoader.resolve_path() == WorldLoader.SAMPLE_PATH, "何も指定がなければ、サンプルの世界を使う")
	WorldLoader.selected_path = "/chosen/world.glb"
	check(WorldLoader.resolve_path() == "/chosen/world.glb", "タイトル画面で選んだ世界を、ゲーム本体へ引き継ぐ")
	WorldLoader.selected_path = ""

	_write_credit('{"credit": "データ名を加工して作成", "license_url": "https://example.com/license", "origin": [1, 2, 3]}')
	var credit := WorldLoader.credit_for("user://credit_test.glb")
	check(credit.credit == "データ名を加工して作成" and credit.license_url == "https://example.com/license", "データの隣の .json から出典を読む")
	_write_credit('{"credit": 123, "license_url": ["x"]}')
	check(WorldLoader.credit_for("user://credit_test.glb") == {"credit": "", "license_url": ""}, "出典が文字でない時は、無視する")
	_write_credit("これは JSON ではありません")
	check(WorldLoader.credit_for("user://credit_test.glb") == {"credit": "", "license_url": ""}, "壊れた .json でも、止まらず空にする")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CREDIT))
	check(WorldLoader.credit_for("user://credit_test.glb") == {"credit": "", "license_url": ""}, ".json がなければ、空にする")


func _test_font() -> void:
	var font := ThemeDB.get_project_theme().default_font
	check(font != null and font.has_char(ord("B")), "既定の書体に、英字がある")
	check(font != null and font.has_char(ord("あ")) and font.has_char(ord("静")), "既定の書体に、日本語がある (どの OS でも同じ書体で出る)")


func _test_title() -> void:
	var title := _start("res://assets/sample_world.glb")
	await process_frame
	await process_frame

	var heading: Label = title.get_node("UI/Menu/TitleLabel")
	check(heading.text == "BOKKE-SOUL", "タイトルは BOKKE-SOUL")
	check(heading.text == heading.text.to_upper(), "タイトルは大文字")
	check(title.start_button.has_focus(), "最初は「はじめる」にフォーカスがある (キーボードで選べる)")
	check(title.camera.current, "カメラが背景の世界を映す")
	check(title.world_root.get_child_count() == 1, "背景に世界が置かれる")
	check(not title.credits_panel.visible, "クレジットは最初は閉じている")
	check(not title.attribution.visible, "出典のないデータ (サンプル) では、隅に出典を出さない")
	check("人工のサンプル" in title.credits_body.text, "クレジットに、サンプルだと書く")
	check("Cinzel" in title.credits_body.text and "Zen Old Mincho" in title.credits_body.text and "Godot" in title.credits_body.text, "クレジットに、書体とエンジンを載せる")

	var before: float = title.camera.rotation.y
	for i in 20:
		await process_frame
	check(title.camera.rotation.y != before, "カメラがゆっくり見回す")

	# クレジットの開閉
	title.credits_button.pressed.emit()
	check(title.credits_panel.visible and title.back_button.has_focus(), "「クレジット」で開く")
	check(not title.menu.visible, "クレジットを開いている間は、タイトルとメニューを隠す")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	title._unhandled_input(escape)
	check(not title.credits_panel.visible and title.credits_button.has_focus(), "Esc で閉じて、元のボタンに戻る")
	check(title.menu.visible, "閉じると、メニューが戻る")
	title.credits_button.pressed.emit()
	title.back_button.pressed.emit()
	check(not title.credits_panel.visible, "「もどる」で閉じる")

	# 出典がある世界では、隅とクレジットに出る
	title.apply_credit({"credit": "VIRTUAL SHIZUOKA (静岡県) を加工して作成 / CC BY 4.0", "license_url": "https://creativecommons.org/licenses/by/4.0/"})
	check(title.attribution.visible and "静岡県" in title.attribution.text, "出典があれば、隅に小さく出す")
	check("creativecommons.org/licenses/by/4.0" in title.credits_body.text and "静岡県" in title.credits_body.text, "クレジットに、出典とライセンスの URL を載せる")
	check(not ("人工のサンプル" in title.credits_body.text), "出典があれば、サンプルとは書かない")

	# 出典が長くても、はみ出さず折り返す
	title.apply_credit({"credit": "短い出典", "license_url": ""})
	for i in 3:
		await process_frame
	check(title.attribution.get_line_count() == 1, "短い出典は、1 行で出る")
	title.apply_credit({"credit": "とても長い出典の文。" + "データの提供元と加工の内容を、省略せずにすべて書くと、このように長くなる。".repeat(6), "license_url": ""})
	for i in 3:
		await process_frame
	check(title.attribution.get_line_count() > 1, "長い出典は、折り返して出る")

	# 「はじめる」で、選んだ世界を渡して始まる
	var received: Array[String] = []
	title.start_requested.connect(func(path: String) -> void: received.append(path))
	title.start_button.pressed.emit()
	check(received == ["res://assets/sample_world.glb"], "「はじめる」で、選んだ世界の場所を渡す")
	check(title.quit_button != null and title.quit_button.text == "おわる", "「おわる」がある")
	title.queue_free()
	await process_frame


func _test_fallback() -> void:
	# 世界が読めなくても、タイトル画面は出る (空だけを見せる)
	var title := _start("/nonexistent/world.glb")
	await process_frame
	check(title.start_button.has_focus() and title.world_root.get_child_count() == 0, "世界が読めなくても、タイトル画面は止まらない")
	title.queue_free()
	await process_frame
