extends SceneTree
## Headless unit tests for the data-driven systems.
##   godot --headless --path . --script res://tests/run_tests.gd

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_tree_data()
	_test_purchase_rules()
	_test_resolver()
	_test_roast_judge()
	_test_roast_director()
	_test_roast_bank_schema()
	_test_scaling_and_morale()
	_test_save_roundtrip()
	print("\n%d checks, %d failures" % [_checks, _failures])
	print("TESTS PASS" if _failures == 0 else "TESTS FAIL")
	quit(0 if _failures == 0 else 1)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("  FAIL: " + what)


func near(a: float, b: float, eps := 0.001) -> bool:
	return abs(a - b) <= eps


func _db() -> ToolsetTreeDB:
	return ToolsetTreeDB.from_files(JsonUtil.list_json("res://data/toolset"))


func _test_tree_data() -> void:
	print("tree data")
	var db := _db()
	check(db.errors.is_empty(), "tree has no validation errors: %s" % [db.errors])
	check(db.branches.size() == 5, "five branches")
	check(db.branches.map(func(b): return b.branch) == ["ED", "CP", "DB", "VC", "BP"], "branch order")
	check(db.nodes.size() == 15, "T0-T1 slice has 15 nodes (got %d)" % db.nodes.size())
	# Cost formula: round(base * 1.65^tier, nearest 50)
	for id in db.nodes:
		var n: Dictionary = db.nodes[id]
		var base: float = {"core": 300.0, "modifier": 400.0, "ability": 600.0}.get(n.type, 0.0)
		var expect := int(round(base * pow(1.65, n.tier) / 50.0) * 50)
		check(n.cost.studio_credits == expect, "%s cost %d == %d" % [id, n.cost.studio_credits, expect])
	check(db.tree_hash.length() == 32, "tree hash computed")
	check(db.tree_hash == _db().tree_hash, "tree hash deterministic")


func _test_purchase_rules() -> void:
	print("purchase rules")
	var db := _db()
	var s := PlayerToolsetState.new()
	check(s.check_purchase(db, "ED_T0_CORE", 0) == "insufficient_studio_credits", "needs credits")
	s.add_currency("studio_credits", 5000)
	check(s.check_purchase(db, "NOPE", 1) == "unknown_node", "unknown node")
	check(s.check_purchase(db, "ED_T1_CORE", 1) == "missing_prereq", "core chain prereq")
	check(s.purchase(db, "ED_T0_CORE", 0) == "", "buy T0 core")
	check(s.currencies.studio_credits == 4700, "credits deducted")
	check(s.check_purchase(db, "ED_T0_CORE", 0) == "already_unlocked", "no double buy")
	check(s.check_purchase(db, "ED_T1_CORE", 0) == "milestone_locked", "T1 gated by milestone")
	check(s.check_purchase(db, "ED_T1_MOD_WEAK", 1) == "missing_prereq", "modifier needs tier core")
	check(s.purchase(db, "ED_T1_CORE", 1) == "", "buy T1 core at milestone 1")
	check(s.purchase(db, "ED_T1_MOD_WEAK", 1) == "", "buy T1 modifier")
	check(s.sc_spent == 1450, "sc_spent tracked (%d)" % s.sc_spent)
	# Refactor: first free, then 15%, +5% each, cap 40%.
	check(s.respec_fee() == 0, "first refactor free")
	s.respec(db)
	check(s.unlocked.is_empty() and s.currencies.studio_credits == 5000, "full refund on free refactor")
	s.purchase(db, "ED_T0_CORE", 0)
	check(s.respec_fee() == int(round(300 * 0.15)), "second refactor 15%")
	s.respec_count = 10
	check(s.respec_fee() == int(round(300 * 0.40)), "refactor fee capped at 40%")
	# Sanitize drops orphaned nodes from tampered saves.
	var t := PlayerToolsetState.from_dict({"unlocked_nodes": ["ED_T1_CORE", "FAKE"], "currencies": {"studio_credits": -5}})
	var dropped := t.sanitize(db)
	check(t.unlocked.is_empty() and dropped.size() == 2, "sanitize drops orphan + unknown")
	check(t.currencies.studio_credits == 0, "negative currency clamped")


func _test_resolver() -> void:
	print("stat resolver")
	var db := _db()
	var r := StatResolver.new()
	r.rebuild(db, ["ED_T0_CORE", "ED_T1_CORE", "ED_T1_MOD_WEAK", "DB_T0_CORE", "DB_T1_CORE", "CP_T0_CORE", "CP_T1_MOD_CHG", "VC_T0_CORE", "VC_T1_CORE"])
	var ctx := {"weapon_tags": ["ballistic", "patch"]}
	check(near(r.get_stat("damage", 100.0, ctx), 108.0), "+8% damage")
	check(near(r.get_stat("crit_chance", 0.05, ctx), 0.10), "+5% crit chance (flat)")
	check(near(r.get_stat("max_hp", 100.0), 115.0), "+15% max hp")
	check(r.has_tag("show_damage_numbers"), "grant_tag")
	# Conditional more: Precompiled Headers only for #patch AND #energy (the railgun).
	check(near(r.get_stat("charge_time", 1.0, {"weapon_tags": ["narrative", "energy"]}), 1.0), "charge mod skips NIB")
	check(near(r.get_stat("charge_time", 1.0, {"weapon_tags": ["patch", "energy"]}), 0.8), "charge mod hits railgun")
	# Full damage formula: weak point = 2.0 * (1 + 0.2), crit = 1.5, window 2.5.
	var hit := r.compute_damage(100.0, ctx, {"crit": true, "weakpoint": true, "window_mult": 2.5, "resist": 0.3})
	var expect := 100.0 * 1.08 * 2.5 * 1.5 * 2.4 * 0.7
	check(near(hit.amount, expect, 0.01), "damage formula %.2f == %.2f" % [hit.amount, expect])
	# "more" product including the window is capped at x6.
	var capped := r.compute_damage(100.0, ctx, {"window_mult": 3.0, "extra_more": [1.0, 0.5]})
	check(near(capped.amount, 100.0 * 1.08 * 6.0, 0.01), "more cap x6 (%.2f)" % capped.amount)
	# Dynamic conditions are evaluated live, not cached.
	r._dynamic_mods.append({"stat": "damage", "bucket": "increased", "value": 0.5, "conditions": {"player_state": {"morale_gte": 50}}, "source": "test"})
	check(near(r.get_stat("damage", 100.0, {"player_state": {"morale": 10}}), 108.0), "dynamic mod off")
	check(near(r.get_stat("damage", 100.0, {"player_state": {"morale": 60}}), 158.0), "dynamic mod on")
	check(StatResolver.conditions_met({"coop_allies_within_m": 10}, {"nearest_ally_m": 4.0}), "ally range met")
	check(not StatResolver.conditions_met({"target_tags_any": ["boss"]}, {"target_tags": ["enemy"]}), "target tag gate")


func _test_roast_judge() -> void:
	print("roast judge")
	check(RoastJudge.judge("CRAFT", "MIRROR", true, 50, 120, 300) == RoastJudge.PERFECT, "perfect")
	check(RoastJudge.judge("CRAFT", "MIRROR", true, -250, 120, 300) == RoastJudge.GOOD, "good (early)")
	check(RoastJudge.judge("CRAFT", "RECEIPTS", true, 10, 120, 300) == RoastJudge.DEFLECTED, "wrong counter, good timing")
	check(RoastJudge.judge("CRAFT", "MIRROR", false, 0, 120, 300) == RoastJudge.DEFLECTED, "right counter, no deflect")
	check(RoastJudge.judge("CRAFT", "MIRROR", true, 900, 120, 300) == RoastJudge.DEFLECTED, "right counter, late deflect")
	check(RoastJudge.judge("CRAFT", "RECEIPTS", true, 900, 120, 300) == RoastJudge.ROASTED, "wrong + missed")
	check(RoastJudge.judge("CRAFT", "", false, 0, 120, 300) == RoastJudge.ROASTED, "no input")
	check(RoastJudge.judge("LIVE", "", true, 10, 120, 300, "assisted_select") == RoastJudge.PERFECT, "assisted select")
	check(RoastJudge.judge("LIVE", "PLAYER_COUNT", false, 0, 120, 300, "one_button") == RoastJudge.GOOD, "one-button")
	check(RoastJudge.judge("LIVE", "", false, 0, 120, 300, "full_auto") == RoastJudge.GOOD, "full auto never perfect")
	check(RoastJudge.judge_backup("HYPE", "RECEIPTS", true, 100, 120, 300) == RoastJudge.GOOD, "backup halves windows")
	check(near(RoastJudge.compensate(1000, 1100, 400), 1000), "lag comp within rtt/2")
	check(near(RoastJudge.compensate(800, 1100, 1000), 950), "lag comp capped at 150 ms")
	check(near(RoastJudge.compensate(1200, 1100, 100), 1100), "no claiming the future")
	var w := RoastJudge.damage_window(RoastJudge.PERFECT, 2)
	check(near(w.duration_s, 5.0) and near(w.mult, 3.0), "backups extend window, cap x3")
	check(near(RoastJudge.damage_window(RoastJudge.GOOD, 0).mult, 1.5), "good window x1.5")


func _test_roast_director() -> void:
	print("roast director")
	var bank: Dictionary = JsonUtil.load_file("res://data/roasts/facilitator_prime.json")
	var d := RoastDirector.new()
	d.setup(bank, 42)
	var state := {"phase": 1, "players": 1, "hype_stacks": 0, "max_rating": "T"}
	var times: Array = []
	var ids: Array = []
	var t := 0.0
	while t < 600.0:
		var line := d.tick(0.1, state)
		t += 0.1
		if not line.is_empty():
			times.append(t)
			ids.append(line.id)
	check(times.size() > 20, "roasts fire over 10 minutes (%d)" % times.size())
	var min_gap := 999.0
	for i in range(1, times.size()):
		min_gap = min(min_gap, times[i] - times[i - 1])
	check(min_gap >= 14.0 - 0.01, "phase 1 interval respected (min gap %.1f)" % min_gap)
	var no_immediate_repeat := true
	for i in range(1, ids.size()):
		no_immediate_repeat = no_immediate_repeat and ids[i] != ids[i - 1]
	check(no_immediate_repeat, "no line plays twice in a row")
	var first7 := ids.slice(0, 7)
	var uniq := {}
	for x in first7:
		uniq[x] = true
	check(uniq.size() == 7, "shuffle bag: first 7 of 10 lines are unique")
	# Context trigger pre-empts the timer but respects the 6 s minimum gap.
	var d2 := RoastDirector.new()
	d2.setup(bank, 7)
	d2.time_until_next = 100.0
	d2.since_last = 0.0
	d2.notify_context("player_low_hp")
	var fired_at := -1.0
	t = 0.0
	while t < 10.0 and fired_at < 0.0:
		var l := d2.tick(0.1, state)
		t += 0.1
		if not l.is_empty():
			fired_at = t
			pass
	check(fired_at < 0.0, "context expires before min gap when TTL short")
	d2.since_last = 10.0
	d2.notify_context("player_low_hp")
	var l2 := d2.tick(0.1, state)
	check(not l2.is_empty(), "context trigger pre-empts timer")
	check(d2.tick(0.1, {"phase": 1, "roast_active": true}).is_empty(), "never overlaps")
	d2.since_last = 99.0
	d2.time_until_next = 0.0
	check(d2.tick(0.1, {"phase": 1, "damage_window": true}).is_empty(), "never during a damage window")


func _test_roast_bank_schema() -> void:
	print("roast bank schema")
	for p in JsonUtil.list_json("res://data/roasts"):
		var bank: Dictionary = JsonUtil.load_file(p)
		check(bank.has("boss_id") and bank.has("home_category"), "%s header" % p)
		for l in bank.lines:
			check(RoastJudge.CATEGORIES.has(l.category), "%s category" % l.id)
			check(l.punch_ms > 0 and l.punch_ms < l.duration_ms, "%s punch inside line" % l.id)
			check(l.has("text_key") and l.has("text_en") and l.has("rating"), "%s fields" % l.id)


func _test_scaling_and_morale() -> void:
	print("scaling + morale")
	check(near(CoopScaling.enemy_hp_mult(2), 1.6), "enemy hp x1.6 at 2p")
	check(near(CoopScaling.boss_hp_mult(4), 3.25), "boss hp x3.25 at 4p")
	check(CoopScaling.scaled_count(6, 2) == 8, "6 enemies -> 8 at 2p")
	check(MoraleRules.band(10) == "normal" and MoraleRules.band(50) == "fatigued", "bands low")
	check(MoraleRules.band(85) == "burnt" and MoraleRules.band(100) == "crunch", "bands high")


func _test_save_roundtrip() -> void:
	print("save")
	var path := "user://test_save.json"
	var d := SaveGame.default_save()
	d.milestone = 1
	d.toolset_tree.unlocked_nodes = ["ED_T0_CORE"]
	check(SaveGame.write_save(path, d), "write save")
	var back := SaveGame.load_save(path)
	check(int(back.milestone) == 1 and back.toolset_tree.unlocked_nodes == ["ED_T0_CORE"], "roundtrip")
	check(int(back.save_version) == SaveGame.SAVE_VERSION, "version stamped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
