extends SceneTree

# 実行: godot --headless --path game --script res://tests/combat_test.gd
# 戦闘の土台を確かめる: 操作の割り当て、武器、攻撃 (3 連続、1 回の攻撃で 1 度だけ当たる、前方だけ)、回避 (進む、最初は攻撃を受けない)、
# スタミナ (使う、回復する、なければ動けない)、体力、体力とスタミナの棒、的 (数字、倒れる、起き上がる)、マウスを戻す時は攻撃しない

var failures: Array[String] = []


func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures.append(label)


func _action_event(name: String) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = true
	return event


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _has(action: String, test: Callable) -> bool:
	for event in InputMap.action_get_events(action):
		if test.call(event):
			return true
	return false


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var player: CharacterBody3D = scene.get_node("Player")
	await _frames(60)
	var combat: PlayerCombat = player.combat
	var character: CharacterModel = player.character

	# 操作の割り当て (Mac で、コントローラーがなくても、マウスとキーボードで、すべてできる)
	check(_has("attack", func(e: InputEvent) -> bool: return e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT), "攻撃は、マウスの左ボタン")
	check(_has("attack", func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_J), "攻撃は、J でもできる (トラックパッドでも)")
	check(_has("attack", func(e: InputEvent) -> bool: return e is InputEventJoypadButton and e.button_index == JOY_BUTTON_RIGHT_SHOULDER), "攻撃は、パッドの RB (実機での確認は、まだ)")
	check(_has("dodge", func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_Q) and _has("dodge", func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_ALT), "回避は、Q か Option (Ctrl は、Mac では右クリックになるので使わない)")
	check(_has("dodge", func(e: InputEvent) -> bool: return e is InputEventJoypadButton and e.button_index == JOY_BUTTON_LEFT_SHOULDER), "回避は、パッドの LB (実機での確認は、まだ)")

	# 武器と、体力・スタミナの棒
	check(character.weapon != null and character.weapon.get_parent().name == "handslot_r", "右手の付け根に、剣を持っている")
	check(player.vitals != null and is_equal_approx(player.vitals.health_bar.size.x, Vitals.BAR_WIDTH) and is_equal_approx(player.vitals.stamina_bar.size.x, Vitals.BAR_WIDTH), "体力とスタミナの棒が、画面に出ていて、満タン")

	# 前方の的に当てる: 1 回の攻撃で、1 度だけ当たる
	var dummy := TrainingDummy.new()
	scene.add_child(dummy)
	dummy.global_position = player.global_position + Vector3(0.0, 0.0, -1.3)  # 体の正面 (-Z)
	await _frames(2)
	var hits: Array[float] = []
	combat.hit_landed.connect(func(_t: Node, d: float) -> void: hits.append(d))
	check(combat.try_attack(), "攻撃できる")
	check(is_equal_approx(combat.stamina, PlayerCombat.MAX_STAMINA - PlayerCombat.ATTACK_COST) and combat.is_busy(), "攻撃で、スタミナを使う。攻撃の間は、動作中")
	check(player.vitals.stamina_bar.size.x < Vitals.BAR_WIDTH - 1.0, "スタミナの棒が、減る")
	await create_timer(0.55).timeout
	check(hits == [12.0] and is_equal_approx(dummy.health, TrainingDummy.MAX_HEALTH - 12.0), "前方の的に、当たる (1 撃目の 12): %s" % [hits])
	await create_timer(0.15).timeout
	check(hits.size() == 1, "1 回の攻撃で、同じ的に、2 度は当たらない")
	player.velocity = Vector3(7.0, 0.0, 0.0)
	check(combat.move_factor() < 1.0, "攻撃の間は、ほとんど動けない (速さの割合 %.2f)" % combat.move_factor())

	# 3 連続 (攻撃の最中に、もう一度押すと、続けて次の攻撃)。3 撃目は、重い
	await create_timer(0.5).timeout  # 1 撃目が終わる
	check(not combat.is_busy(), "1 撃目が終わると、動作中でなくなる")
	combat.try_attack()
	var queued_second := combat.try_attack()  # 2 撃目の最中に、押す → 3 撃目を予約
	await create_timer(1.0).timeout
	check(queued_second and hits.size() >= 2 and hits[1] == 14.0, "続けて攻撃すると、2 撃目 (14) が当たる: %s" % [hits])
	await create_timer(1.0).timeout
	check(hits.size() >= 3 and hits[2] == 22.0, "3 撃目は、重い (22): %s" % [hits])
	check(not combat.try_attack() or combat.is_busy(), "(確認の準備) 3 撃目の最中に、押した")
	await create_timer(1.4).timeout
	check(dummy.is_defeated and dummy.health == 0.0, "的は、体力がなくなると、倒れる (体力 %.0f)" % dummy.health)
	var defeated_hits := hits.size()
	dummy.take_damage(5.0)
	check(dummy.health == 0.0 and hits.size() == defeated_hits, "倒れている間は、ダメージを受けない")
	dummy._get_up()
	check(dummy.health == TrainingDummy.MAX_HEALTH and not dummy.is_defeated, "しばらくすると、起き上がる (体力が戻る)")

	# 前方だけ: 後ろや、遠くの的には、当たらない
	await create_timer(1.0).timeout
	var behind := TrainingDummy.new()
	scene.add_child(behind)
	behind.global_position = player.global_position + Vector3(0.0, 0.0, 1.3)
	var far := TrainingDummy.new()
	scene.add_child(far)
	far.global_position = player.global_position + Vector3(0.0, 0.0, -4.0)
	dummy.global_position = player.global_position + Vector3(8.0, 0.0, 0.0)
	await _frames(2)
	await create_timer(1.2).timeout  # スタミナが戻る
	combat.try_attack()
	await create_timer(0.9).timeout
	check(behind.health == TrainingDummy.MAX_HEALTH and far.health == TrainingDummy.MAX_HEALTH, "後ろの的と、遠くの的には、当たらない")

	# スタミナ: 使い切ると、攻撃も回避もできない。しばらくすると、回復する
	await create_timer(1.0).timeout
	combat.stamina = 0.0
	check(not combat.try_attack() and not combat.try_dodge(Vector3.RIGHT), "スタミナがなければ、攻撃も、回避もできない")
	await create_timer(0.7 + 0.3).timeout
	check(combat.stamina > 5.0, "使ったあと、少し待つと、スタミナが回復する (%.1f)" % combat.stamina)

	# 回避: 進む。最初の間は、攻撃を受けない
	combat.stamina = PlayerCombat.MAX_STAMINA
	var start := player.global_position
	check(combat.try_dodge(Vector3.RIGHT) and combat.is_dodging(), "回避できる")
	check(is_equal_approx(combat.stamina, PlayerCombat.MAX_STAMINA - PlayerCombat.DODGE_COST), "回避で、スタミナを使う")
	check(not player.take_damage(10.0) and is_equal_approx(combat.health, PlayerCombat.MAX_HEALTH), "回避の最初の間は、攻撃を受けない")
	check(not player.combat.try_dodge(Vector3.RIGHT), "回避の最中に、重ねて回避はできない")
	check(character.state == "roll" and absf(player.model.rotation.y - atan2(-1.0, 0.0)) < 0.01, "向きの入力があれば、その向きへ体を向けて、転がる (%s)" % character.state)
	await create_timer(0.25).timeout
	check(not character.transform.basis.is_equal_approx(Basis.IDENTITY), "転がっている間は、体が、前へ回っている")
	await create_timer(0.7).timeout
	check(not combat.is_dodging() and character.transform.basis.is_equal_approx(Basis.IDENTITY), "転がり終わると、体は、元の向きに戻る")
	check(not combat.is_dodging() and absf(player.global_position.x - start.x) > 2.0, "回避で、指定の向きへ、進む (%.1f m)" % (player.global_position.x - start.x))
	check(player.take_damage(10.0) and is_equal_approx(combat.health, PlayerCombat.MAX_HEALTH - 10.0), "回避が終われば、ダメージを受ける (体力 %.0f)" % combat.health)
	check(is_equal_approx(player.vitals.health_bar.size.x, Vitals.BAR_WIDTH * 0.9), "体力の棒が、減る")

	# 向きの入力がなければ、後ろへ飛びのく (転がらない)
	await create_timer(1.0).timeout
	combat.stamina = PlayerCombat.MAX_STAMINA
	var back_start := player.global_position
	var facing_before: float = player.model.rotation.y
	check(combat.try_dodge(Vector3.ZERO) and character.state == "dodge_backward", "向きの入力がなければ、後ろへ飛びのく (%s)" % character.state)
	await create_timer(0.2).timeout
	check(character.transform.basis.is_equal_approx(Basis.IDENTITY) and is_equal_approx(player.model.rotation.y, facing_before), "飛びのく時は、転がらず、体の向きも変わらない")
	await create_timer(0.6).timeout
	check(player.global_position.distance_to(back_start) > 2.0, "後ろへ、進む (%.1f m)" % player.global_position.distance_to(back_start))

	# 動作中は、休めない・跳べない
	await create_timer(1.0).timeout
	combat.try_attack()
	var rested := [false]
	player.rested.connect(func(_p: Vector3) -> void: rested[0] = true)
	player.rest()
	check(not rested[0], "攻撃の最中は、休めない")
	await create_timer(1.0).timeout

	# マウスが外れている時の左クリックは、マウスを戻すだけで、攻撃しない
	player.mouse_captured = false  # (ヘッドレスでは、Input.mouse_mode が動かないので、印で確かめる)
	var before := combat.stamina
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	player._unhandled_input(click)
	check(player.mouse_captured and is_equal_approx(combat.stamina, before) and not combat.is_busy(), "マウスが外れている時の左クリックは、マウスを戻すだけ (攻撃しない)")
	player._unhandled_input(click)
	check(combat.is_busy(), "マウスを戻したあとの左クリックは、攻撃になる")

	# 体力がなくなる
	await create_timer(1.2).timeout
	var died := [false]
	combat.died.connect(func() -> void: died[0] = true)
	combat.health = 5.0
	player.take_damage(50.0)
	check(died[0] and combat.health == 0.0 and not combat.try_attack(), "体力がなくなると、倒れて、攻撃も、回避もできない")
	quit(1 if failures.size() > 0 else 0)
