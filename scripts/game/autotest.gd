class_name AutoTest
extends Node
## Headless end-to-end checks that drive the real game through its real network paths.
##   Solo:   godot --headless --path . -- --solo --autotest=solo
##   Co-op:  godot --headless --path . -- --host --autotest=host
##           godot --headless --path . -- --join=127.0.0.1 --autotest=client
## Prints "AUTOTEST PASS" / "AUTOTEST FAIL: ..." and exits 0 / 1.

const TIMEOUT_S := 150.0

var mode := "solo"
var _failed := false
var _perfects := 0
var _ratiod := false
var _last_result := ""
var _results_for_me: Array = []


func _ready() -> void:
	get_tree().create_timer(TIMEOUT_S).timeout.connect(func(): _fail("timed out"))
	_log("mode=%s" % mode)
	match mode:
		"solo":
			_run_solo()
		"host":
			_run_host()
		"client":
			_run_client()
		"shots":
			_run_shots()
		"menu_shot":
			await _sleep(1.5)
			await _shot("00_menu.png")
			_pass()


func _log(t: String) -> void:
	print("[autotest:%s] %s" % [mode, t])


func _fail(why: String) -> void:
	if _failed:
		return
	_failed = true
	print("AUTOTEST FAIL: %s" % why)
	get_tree().quit(1)


func _pass() -> void:
	if _failed:
		return
	print("AUTOTEST PASS")
	get_tree().quit(0)


func _check(cond: bool, what: String) -> bool:
	if cond:
		_log("ok  " + what)
	else:
		_fail(what)
	return cond


func _wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	return cond.call()


func _sleep(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _arena() -> Arena:
	return Arena.current


func _aim_at(p: Player, target_pos: Vector3) -> Vector3:
	return (target_pos - p.camera.global_position).normalized()


# =========================================================================================

func _buy_starter_nodes(p: Player) -> bool:
	p._srv_debug_credits.rpc_id(1)
	p._srv_debug_credits.rpc_id(1)
	await _sleep(0.3)
	for id in ["ED_T0_CORE", "DB_T0_CORE", "BP_T0_CORE", "VC_T0_CORE", "VC_T1_CORE"]:
		p.srv_purchase.rpc_id(1, id)
	var ok: bool = await _wait_until(func(): return p.toolset_view.get("unlocked_nodes", []).has("VC_T1_CORE"), 5.0)
	if not _check(ok, "tree purchases confirmed by host (%s)" % [p.toolset_view.get("unlocked_nodes", [])]):
		return false
	await _wait_until(func(): return p.max_hp > 114.0, 2.0)
	return _check(absf(p.max_hp - 115.0) < 0.01, "Local Repo raised max HP to %.0f" % p.max_hp) \
		and _check(p.has_tag("show_damage_numbers") and p.has_tag("ult_available"), "grant_tag effects replicated")


func _counter_roasts(p: Player, wanted_perfects: int, timeout: float) -> void:
	var ui := RoastUi.instance
	var b := _arena().boss()
	var deadline := Time.get_ticks_msec() / 1000.0 + timeout
	while _perfects < wanted_perfects and Time.get_ticks_msec() / 1000.0 < deadline and not _failed:
		b = _arena().boss()
		if b == null:
			return
		if multiplayer.is_server():
			b.director.time_until_next = min(b.director.time_until_next, 0.2)
			b.director.since_last = max(b.director.since_last, 10.0)
		if ui.active and not ui.deflected and ui.target_peer == multiplayer.get_unique_id():
			var cat := str(ui.line.category)
			ui.select_counter(RoastJudge.COUNTERS.find(RoastJudge.COUNTER_FOR[cat]))
			var punch := ui._punch_ms()
			await _wait_until(func(): return Net.server_now_ms() >= punch - 8.0, 10.0)
			ui.press_deflect()
			_log("deflected %s line %s at %+.0f ms" % [cat, ui.line.id, ui.deflect_offset_ms])
			await _wait_until(func(): return not ui.active, 6.0)
		await get_tree().physics_frame


func _on_roast_finished(_uid: int, primary: String, results: Dictionary, ratiod: bool) -> void:
	_last_result = primary
	var mine: Dictionary = results.get(multiplayer.get_unique_id(), {})
	if mine.get("role", "") == "primary":
		_results_for_me.append(mine.result)
		if mine.result == "PERFECT":
			_perfects += 1
	if ratiod:
		_ratiod = true
	_log("roast resolved: %s (mine: %s)%s" % [primary, mine, " RATIO'D" if ratiod else ""])


# =========================================================================================

func _run_solo() -> void:
	RoastUi.instance.roast_finished.connect(_on_roast_finished)
	if not await _wait_until(func(): return Player.local != null, 5.0):
		return _fail("local player never spawned")
	var p := Player.local
	var a := _arena()
	_log("player spawned at %s" % p.global_position)
	if not await _buy_starter_nodes(p):
		return
	# Waves: wait for enemies, then shoot them with the Hotfix Shotgun through the host path.
	if not await _wait_until(func(): return not a.enemies().is_empty(), 15.0):
		return _fail("wave 1 never spawned")
	_check(a.flow == "wave" and a.wave == 1, "wave 1 running")
	var sc_before := int(p.wallet.get("studio_credits", 0))
	var killed: bool = await _wait_until(func(): return _shoot_nearest(p, "HFS") and int(p.wallet.get("studio_credits", 0)) > sc_before, 25.0)
	if not _check(killed, "Hotfix Shotgun killed an intern and kill credits arrived (%d -> %d SC)" % [sc_before, int(p.wallet.get("studio_credits", 0))]):
		return
	# Narrative Integrity Blaster: charged shot opens a dialogue choice.
	p._switch_weapon(1)
	var opened: bool = await _wait_until(func(): return _charged_nib(p) or not p.dialogue_pending.is_empty(), 15.0)
	if not _check(opened and not p.dialogue_pending.is_empty(), "charged NIB froze a target in a dialogue wheel"):
		return
	var e_name := str(p.dialogue_pending.enemy)
	p._srv_dialogue_choice.rpc_id(1, e_name, "lie")
	p.dialogue_pending.clear()
	await _sleep(0.2)
	var e := a.enemy_by_name(e_name)
	_check(e == null or e.team == "player", "[Lie] converted the target into an ally")
	# Scope Creep Launcher spawns a feature.
	p._switch_weapon(2)
	var spawned: bool = await _wait_until(func(): return _shoot_nearest(p, "SCL") and a.features._live.size() > 0, 10.0)
	_check(spawned, "Scope Creep Launcher spawned a feature")
	# Boss.
	a._start_boss()
	if not await _wait_until(func(): return a.boss() != null, 3.0):
		return _fail("boss did not spawn")
	var b := a.boss()
	_check(b.max_hp == float(b.def.hp), "solo boss HP unscaled (%d)" % b.max_hp)
	# Phase gate: outside a window the boss can't drop below 66%.
	b.server_damage(b.max_hp * 0.5, null)
	_check(b.phase == 1 and b.hp > b.max_hp * 0.66, "phase gate holds outside damage windows")
	await _counter_roasts(p, 1, 40.0)
	if not _check(_perfects >= 1, "PERFECT counter landed (%s)" % [_results_for_me]):
		return
	_check(b.in_window() and absf(b.window_mult() - 2.5) < 0.01, "Ego Crack window x2.5 open")
	# Shoot the exposed weak point during the window and verify the multiplier path.
	var hp0 := b.hp
	p._switch_weapon(0)
	var weak_pos := b.weak_area.global_position
	await _wait_until(func(): return _fire_at(p, "HFS", weak_pos) and b.hp < hp0, 3.0)
	_check(b.hp < hp0, "weak-point hits during the window damaged the boss (%.0f -> %.0f)" % [hp0, b.hp])
	_check(b.phase >= 2, "phase transition allowed inside the window (phase %d)" % b.phase)
	await _counter_roasts(p, 3, 90.0)
	_check(_ratiod, "three PERFECTs in a row triggered RATIO'D")
	# Finish it inside the RATIO'D stun window.
	b = a.boss()
	if b:
		await _wait_until(func(): return b.in_window() or b.mode == "stunned", 5.0)
		b.server_damage(b.hp + 10.0, p)
	if not await _wait_until(func(): return a.flow == "shipped", 3.0):
		return _fail("boss defeat did not ship the milestone")
	await _sleep(0.5)
	var saved := SaveGame.load_save(Game.save_path)
	_check(int(saved.milestone) >= 1 and int(saved.currencies.keystone_tokens) >= 1, "save written: milestone %d, %d KT" % [int(saved.milestone), int(saved.currencies.keystone_tokens)])
	_check(saved.toolset_tree.unlocked_nodes.has("VC_T1_CORE"), "tree persisted to save")
	_pass()


func _nearest_enemy(p: Player) -> Enemy:
	var best: Enemy = null
	var bd := INF
	for e in _arena().enemies():
		if e.team != "enemy" or e.state == "stunned":
			continue
		var d := p.global_position.distance_to(e.global_position)
		if d < bd:
			bd = d
			best = e
	return best


func _shoot_nearest(p: Player, wid: String) -> bool:
	var e := _nearest_enemy(p)
	if e:
		_fire_at(p, wid, e.center())
	return true


func _fire_at(p: Player, wid: String, pos: Vector3) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now >= p._local_ready_at:
		p.fire_weapon(wid, 0.0, _aim_at(p, pos))
	return true


func _charged_nib(p: Player) -> bool:
	var e := _nearest_enemy(p)
	var now := Time.get_ticks_msec() / 1000.0
	if e and now >= p._local_ready_at and now - p._last_charged_shot > 1.0:
		p._last_charged_shot = now - 2.0  # host also tracks this; give it a full charge
		p.fire_weapon("NIB", 1.0, _aim_at(p, e.center()))
	return false


# =========================================================================================

func _run_host() -> void:
	RoastUi.instance.roast_finished.connect(_on_roast_finished)
	var a := _arena()
	if not await _wait_until(func(): return a.players().size() >= 2, 40.0):
		return _fail("client never joined")
	var client: Player = null
	for p in a.players():
		if p.peer_id != 1:
			client = p
	_log("client %s joined as peer %d" % [client.display_name, client.peer_id])
	if not await _wait_until(func(): return client.toolset.has("ED_T0_CORE"), 20.0):
		return _fail("client purchase never validated on host")
	_check(true, "host validated client's tree purchase")
	a._start_boss()
	await _wait_until(func(): return a.boss() != null, 3.0)
	var b := a.boss()
	_check(absf(b.max_hp - float(b.def.hp) * 1.75) < 1.0, "2-player boss HP scaled x1.75 (%.0f)" % b.max_hp)
	b.force_target_peer = client.peer_id
	if not await _wait_until(func(): return client.damage_dealt_boss > 0.0, 30.0):
		return _fail("client shots never damaged the boss on the host")
	_check(true, "client shots resolved on host (%.0f dmg)" % client.damage_dealt_boss)
	while _last_result == "" and not _failed:
		b.director.time_until_next = min(b.director.time_until_next, 0.2)
		b.director.since_last = max(b.director.since_last, 10.0)
		await get_tree().physics_frame
	_check(_last_result == "PERFECT" or _last_result == "GOOD", "client's networked counter judged %s on host" % _last_result)
	await _sleep(2.0)  # let the client report before we leave
	_pass()


func _run_client() -> void:
	RoastUi.instance.roast_finished.connect(_on_roast_finished)
	if not await _wait_until(func(): return Player.local != null, 20.0):
		return _fail("client player never spawned locally")
	var p := Player.local
	_log("spawned as peer %d; clock offset %.1f ms rtt %.1f ms" % [p.peer_id, Net.server_offset_ms, Net.rtt_ms])
	if not await _buy_starter_nodes(p):
		return
	if not await _wait_until(func(): return _arena().boss() != null, 30.0):
		return _fail("boss never replicated to client")
	_check(true, "boss replicated to client")
	await _wait_until(func():
		var b := _arena().boss()
		if b and not (b.mode == "windup" or b.mode == "delivery"):
			_fire_at(p, "HFS", b.center())
		return RoastUi.instance.active, 40.0)
	await _counter_roasts(p, 1, 40.0)
	_check(_results_for_me.size() > 0 and (_results_for_me[0] == "PERFECT" or _results_for_me[0] == "GOOD"), "client countered over the network: %s" % [_results_for_me])
	_pass()


# =========================================================================================
# Screenshots for docs/PRs (needs a real renderer, e.g. xvfb-run with --rendering-driver opengl3)

func _shot(file: String) -> void:
	await RenderingServer.frame_post_draw
	var dir := str(Game.args.get("shots_dir", "user://shots"))
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir.path_join(file))
	_log("saved %s" % dir.path_join(file))


func _run_shots() -> void:
	if not await _wait_until(func(): return Player.local != null, 5.0):
		return _fail("no player")
	var p := Player.local
	var a := _arena()
	p._srv_debug_credits.rpc_id(1)
	await _sleep(0.3)
	for id in ["ED_T0_CORE", "DB_T0_CORE", "BP_T0_CORE", "ED_T1_CORE"]:
		p.srv_purchase.rpc_id(1, id)
	await _wait_until(func(): return a.enemies().size() >= 4, 15.0)
	await _sleep(2.5)
	for i in 3:
		var e := _nearest_enemy(p)
		if e == null:
			break
		p.look_at(Vector3(e.global_position.x, p.global_position.y, e.global_position.z), Vector3.UP)
		_fire_at(p, "HFS", e.center())
		await _sleep(0.75)
	await _shot("01_wave.png")
	a._start_boss()
	await _wait_until(func(): return a.boss() != null, 3.0)
	for x in a.enemies():
		x.queue_free()
	var b := a.boss()
	p.global_position = Vector3(0, 0.2, 6)
	p.look_at(b.center(), Vector3.UP)
	p.rotation.x = 0.0
	p.rotation.z = 0.0
	p.head.rotation.x = 0.12
	b.director.time_until_next = 0.1
	b.director.since_last = 10.0
	await _wait_until(func(): return RoastUi.instance.active, 5.0)
	var ui := RoastUi.instance
	ui.select_counter(RoastJudge.COUNTERS.find(RoastJudge.COUNTER_FOR[str(ui.line.category)]))
	await _wait_until(func(): return Net.server_now_ms() >= ui._punch_ms() - 450.0, 10.0)
	await _shot("02_roast.png")
	await _wait_until(func(): return Net.server_now_ms() >= ui._punch_ms(), 2.0)
	ui.press_deflect()
	await _wait_until(func(): return not ui.active, 6.0)
	await _sleep(0.3)
	await _shot("03_ego_crack.png")
	get_tree().get_first_node_in_group("tree_ui").toggle()
	await _sleep(0.5)
	await _shot("04_tree.png")
	_pass()
