class_name Boss
extends CharacterBody3D
## Facilitator Prime (GDD 9.1) and the full roast loop (GDD 8): wind-up, delivery,
## punchline, counter + deflect, resolution, damage windows, Hype stacks, RATIO'D.
## Everything is decided on the host; clients render and send CounterInput.

const GRAVITY := 20.0
const RESOLVE_SLACK_MS := 120.0

var boss_id := "FACILITATOR_PRIME"
var def: Dictionary = {}
var arena: Arena

# Replicated.
var sync_pos := Vector3.ZERO
var sync_yaw := 0.0
var hp := 1.0
var max_hp := 1.0
var phase := 1
var hype := 0
var mode := "assault"      # assault | windup | delivery | stunned | dead
var window_left := 0.0
var window_mult_v := 1.0
var melted := false

# Host-only.
var director := RoastDirector.new()
var attack_cd := 3.0
var roast: Dictionary = {}     # active roast instance
var roast_seq := 0
var perfect_streak := 0
var stun_left := 0.0
var _puddle_id := ""
var force_target_peer := 0   # test hook: autotest pins roasts on one player

# Visuals.
var visual: Node3D
var face: Node3D
var weak_mesh: MeshInstance3D
var weak_area: Area3D
var title_label: Label3D


static func create(pos: Vector3, hp_mult: float) -> Boss:
	var b := Boss.new()
	b.name = "Boss"
	b.def = Data.bosses["FACILITATOR_PRIME"]
	b.position = pos
	b.sync_pos = pos
	b.max_hp = float(b.def.hp) * hp_mult
	b.hp = b.max_hp
	b._build()
	return b


func _build() -> void:
	collision_layer = Layers.ENEMY
	collision_mask = Layers.WORLD
	set_meta("hit_owner", self)
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 1.3
	cap.height = 4.2
	shape.shape = cap
	shape.position = Vector3(0, 2.1, 0)
	add_child(shape)
	visual = Node3D.new()
	add_child(visual)
	var wax := Color("#f1d9b5")
	visual.add_child(Fx.capsule(1.1, 3.0, wax, Vector3(0, 1.5, 0)))
	visual.add_child(Fx.box(Vector3(2.6, 2.0, 0.25), Color("#fbfbfb"), Vector3(0, 2.2, -1.0)))  # whiteboard torso
	var scribble := Fx.label("SYNERGY -> ??? -> PROFIT", Color("#2a62ff"), Vector3(0, 2.6, -1.15), 40)
	scribble.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	scribble.rotation_degrees = Vector3(0, 180, 0)
	visual.add_child(scribble)
	face = Node3D.new()
	face.position = Vector3(0, 3.9, 0)
	visual.add_child(face)
	face.add_child(Fx.sphere(0.85, wax.darkened(0.05)))
	face.add_child(Fx.box(Vector3(0.9, 0.12, 0.1), Color("#222222"), Vector3(0, 0.1, -0.8)))
	face.add_child(Fx.box(Vector3(0.6, 0.1, 0.1), Color("#c0392b"), Vector3(0, -0.35, -0.78)))
	for i in 10:  # sticky-note scales and lanyard intestines
		var c := Color("#ffe74c") if i % 2 == 0 else Color("#ff8ad8")
		visual.add_child(Fx.box(Vector3(0.3, 0.3, 0.03), c, Vector3(randf_range(-1.0, 1.0), randf_range(0.6, 2.8), randf_range(-1.1, -0.9))))
	for i in 4:
		visual.add_child(Fx.box(Vector3(0.07, 1.4, 0.03), Color.from_hsv(i * 0.22, 0.8, 1.0), Vector3(-0.6 + i * 0.4, 1.2, -1.15)))
	weak_mesh = Fx.cylinder(0.12, 0.7, Color("#ff2d55"), Vector3(0, 2.0, -1.2))
	weak_mesh.rotation_degrees = Vector3(0, 0, 90)
	weak_mesh.material_override = Fx.mat(Color("#ff2d55"), true)
	weak_mesh.visible = false
	visual.add_child(weak_mesh)
	weak_area = Area3D.new()
	weak_area.collision_layer = 0
	weak_area.collision_mask = 0
	weak_area.monitoring = false
	weak_area.position = Vector3(0, 2.0, -1.25)
	var ws := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.55
	ws.shape = sph
	weak_area.add_child(ws)
	weak_area.set_meta("hit_owner", self)
	weak_area.set_meta("weakpoint", true)
	add_child(weak_area)
	title_label = Fx.label("", Color("#ffd23f"), Vector3(0, 5.6, 0), 44)
	add_child(title_label)
	Fx.add_sync(self, ["sync_pos", "sync_yaw", "hp", "max_hp", "phase", "hype", "mode", "window_left", "window_mult_v", "melted"],
		["hp", "max_hp", "phase", "hype", "mode", "window_mult_v", "melted"])


func _ready() -> void:
	arena = Arena.current
	add_to_group("bosses")
	director.setup(Data.roast_banks[def.roast_bank])


func is_alive() -> bool:
	return mode != "dead" and hp > 0.0


func center() -> Vector3:
	return global_position + Vector3(0, 2.2, 0)


func get_target_tags() -> Array:
	return ["boss", "enemy", boss_id.to_lower()]


func in_window() -> bool:
	return window_left > 0.0


func window_mult() -> float:
	return window_mult_v if window_left > 0.0 else 1.0


## Boss DR: 90% while delivering a roast, plus +5% per Hype stack.
func current_resist() -> float:
	var r := float(def.get("resist", 0.0)) + float(def.hype_stack_dr) * hype
	if mode == "windup" or mode == "delivery":
		r = max(r, float(def.delivery_damage_reduction))
	return min(r, 0.95)


# =========================================================================================

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_server_tick(delta)
		sync_pos = global_position
		sync_yaw = rotation.y
	else:
		global_position = global_position.lerp(sync_pos, clampf(delta * 10.0, 0.0, 1.0))
		rotation.y = lerp_angle(rotation.y, sync_yaw, clampf(delta * 10.0, 0.0, 1.0))
		window_left = max(0.0, window_left - delta)
	_update_visuals(delta)


func _update_visuals(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	# Its face slides down its body as it talks, re-forming each phase.
	var slide := fmod(t * 0.15, 1.0) * (0.6 if mode == "delivery" else 0.2)
	face.position.y = 3.9 - slide - (phase - 1) * 0.3
	visual.scale = Vector3.ONE * (0.55 if melted else 1.0)
	weak_mesh.visible = in_window() or mode == "stunned"
	weak_area.collision_layer = Layers.HITBOX if weak_mesh.visible else 0
	var bits: Array = ["FACILITATOR PRIME"]
	if mode == "windup" or mode == "delivery":
		bits.append("ROASTING...")
	elif in_window():
		bits.append("EGO CRACK x%.1f  %.1fs" % [window_mult_v, window_left])
	elif mode == "stunned":
		bits.append("RATIO'D")
	title_label.text = "\n".join(bits)


# =========================================================================================
# Host: damage
# =========================================================================================

func server_damage(amount: float, source: Player, info: Dictionary = {}) -> bool:
	if not is_alive():
		return false
	var new_hp := hp - amount
	# Phase transitions only happen inside a damage window (GDD 8.3).
	var thresholds: Array = def.phase_thresholds
	if phase - 1 < thresholds.size():
		var gate := float(thresholds[phase - 1]) * max_hp
		if new_hp < gate:
			if in_window() or mode == "stunned":
				_enter_phase(phase + 1)
			else:
				new_hp = gate + 1.0
	if source:
		source.damage_dealt_boss_add(hp - max(new_hp, 0.0))
	hp = new_hp
	if hp <= 0.0:
		_die()
		return true
	return false


func _enter_phase(p: int) -> void:
	phase = p
	director.reset_timer(phase)
	arena.fx_text_all(center() + Vector3.UP * 3.0, "PHASE %d: %s" % [phase, ["", "", "Breakout Rooms unlocked", "IT'S MELTING"][min(phase, 3)]], "#ff8ad8", 64)
	if phase == 3 and not melted:
		melted = true
		var pd: Dictionary = def.puddle
		_puddle_id = arena.spawn_zone(global_position, float(pd.radius_m), "#f1d9b5", float(pd.slow), float(pd.morale_per_s), 9999.0)


func _die() -> void:
	mode = "dead"
	hp = 0.0
	_end_roast_ui()
	if _puddle_id != "":
		arena.remove_zone(_puddle_id)
	arena.on_boss_defeated(self)
	queue_free()


# =========================================================================================
# Host: behaviour
# =========================================================================================

func _server_tick(delta: float) -> void:
	if not is_alive():
		return
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	window_left = max(0.0, window_left - delta)
	if mode == "stunned":
		stun_left -= delta
		if stun_left <= 0.0:
			mode = "assault"
		_halt()
		return
	if not roast.is_empty():
		_roast_tick()
		_halt()
		return
	var line := director.tick(delta, {
		"phase": phase, "roast_active": false, "damage_window": in_window(), "hype_stacks": hype,
		"players": arena.players().size(), "max_rating": "T" if Game.settings.get("streamer_mode", false) else "M",
	})
	if not line.is_empty():
		_start_roast(line)
		return
	_assault_tick(delta)


func _halt() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	move_and_slide()


func _assault_tick(delta: float) -> void:
	var target := _nearest_player()
	if target:
		var to := target.global_position - global_position
		to.y = 0.0
		rotation.y = atan2(-to.x, -to.z)
		var spd := float(def.move_speed[phase - 1])
		if to.length() > 6.0:
			velocity.x = to.normalized().x * spd
			velocity.z = to.normalized().z * spd
		else:
			velocity.x = 0.0
			velocity.z = 0.0
	move_and_slide()
	if in_window():
		return  # staggered by the Ego Crack
	attack_cd -= delta
	if attack_cd <= 0.0:
		attack_cd = float(def.attack_cooldown_s[phase - 1]) * randf_range(0.85, 1.15)
		var options: Array = ["icebreaker", "parking_lot"]
		if phase >= int(def.attacks.breakout_rooms.min_phase):
			options.append("breakout_rooms")
		_attack(options.pick_random())


func _attack(kind: String) -> void:
	var a: Dictionary = def.attacks[kind]
	var dmg_mult := 1.0 + float(def.hype_stack_damage) * hype
	match kind:
		"icebreaker":
			var n := int(a.projectiles)
			var offset := randf() * TAU
			for i in n:
				var ang := offset + TAU * i / n
				var dir := Vector3(cos(ang), 0, sin(ang))
				arena.projectiles.spawn("icebreaker", center() + dir * 1.5, dir * float(a.speed), "enemy", {
					"damage": float(a.damage) * dmg_mult, "morale": float(a.morale), "status": "frozen",
					"status_s": float(a.slow_s), "source": "Icebreaker",
				})
			arena.fx_text_all(center() + Vector3.UP * 2.0, "ICEBREAKER! Share a fun fact!", "#a8e6ff")
		"parking_lot":
			var players := arena.alive_players()
			for i in min(int(a.notes), players.size() + 1):
				var p: Player = players[i % max(players.size(), 1)] if not players.is_empty() else null
				var pos: Vector3 = (p.global_position if p else global_position) + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
				arena.spawn_sticky_note(pos, float(a.radius_m), float(a.arm_s), float(a.root_s), float(a.life_s))
			arena.fx_text_all(center() + Vector3.UP * 2.0, "Let's put that in the PARKING LOT", "#ffe74c")
		"breakout_rooms":
			var L := float(a.arm_length_m)
			for yaw in [0.0, PI * 0.5]:
				arena.spawn_wall(global_position + Vector3.UP * 1.5, Vector3(L * 2.0, 3.0, 0.35), yaw, "#ff8ad8", "BREAKOUT ROOM", float(a.duration_s))
			arena.fx_text_all(center() + Vector3.UP * 2.0, "BREAKOUT ROOMS, EVERYONE!", "#ff8ad8")


func _nearest_player() -> Player:
	var best: Player = null
	var bd := INF
	for p in arena.alive_players():
		var d := global_position.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best


# =========================================================================================
# Host: roast loop
# =========================================================================================

func _start_roast(line: Dictionary) -> void:
	var target := _pick_roast_target(str(line.get("target", "random_player")))
	if target == null:
		return
	roast_seq += 1
	var windup := float(def.windup_ms)
	var t0 := Net.server_now_ms()
	roast = {
		"uid": roast_seq, "line": line, "target": target.peer_id, "t0": t0,
		"punch": t0 + windup + float(line.punch_ms), "end": t0 + windup + float(line.duration_ms),
		"inputs": {},  # peer -> {counter, deflect_ms (host clock) or -1}
	}
	mode = "windup"
	CombatBus.emit_event("on_roast_started", target.peer_id, {"line": line.id})
	_roast_start_rpc.rpc(roast_seq, str(line.id), target.peer_id, t0, windup)


func _pick_roast_target(kind: String) -> Player:
	if force_target_peer != 0 and arena.player_by_peer(force_target_peer):
		return arena.player_by_peer(force_target_peer)
	var ps := arena.alive_players()
	if ps.is_empty():
		ps = arena.players()
	if ps.is_empty():
		return null
	match kind:
		"lowest_hp":
			ps.sort_custom(func(a, b): return a.hp / a.max_hp < b.hp / b.max_hp)
			return ps[0]
		"top_damage":
			ps.sort_custom(func(a, b): return a.damage_dealt_boss > b.damage_dealt_boss)
			return ps[0]
	return ps.pick_random()


func _roast_tick() -> void:
	var now := Net.server_now_ms()
	if mode == "windup" and now >= float(roast.t0) + float(def.windup_ms):
		mode = "delivery"
	var line: Dictionary = roast.line
	var good := float(RoastJudge.windows_for(str(Game.settings.difficulty))[1]) + 400.0
	var resolve_at: float = max(float(roast.end), float(roast.punch) + good + RoastJudge.MAX_LAG_COMP_MS + RESOLVE_SLACK_MS)
	if now >= resolve_at:
		_resolve_roast()


## CounterInput from a client (GDD 8.6). counter may change until Deflect is pressed.
@rpc("any_peer", "call_local", "reliable")
func srv_counter_input(uid: int, counter: String, deflect_client_ms: float) -> void:
	if not multiplayer.is_server() or roast.is_empty() or int(roast.uid) != uid:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var entry: Dictionary = roast.inputs.get(sender, {"counter": "", "deflect": -1.0})
	if entry.deflect >= 0.0:
		return  # deflect locks the answer
	if RoastJudge.COUNTERS.has(counter):
		entry.counter = counter
	if deflect_client_ms >= 0.0:
		var arrival := Net.server_now_ms()
		var claimed := Net.client_to_server_ms(sender, deflect_client_ms)
		entry.deflect = RoastJudge.compensate(claimed, arrival, Net.peer_rtt_ms(sender))
	roast.inputs[sender] = entry


func _resolve_roast() -> void:
	var line: Dictionary = roast.line
	var cat := str(line.category)
	var results := {}
	var primary_result := RoastJudge.ROASTED
	var backups := 0
	for p in arena.players():
		var inp: Dictionary = roast.inputs.get(p.peer_id, {"counter": "", "deflect": -1.0})
		var windows := RoastJudge.windows_for(str(Game.settings.difficulty))
		var perfect_ms: float = float(windows[0]) + p.resolver.get_stat("counter_window_perfect_ms", 0.0)
		var good_ms: float = float(windows[1]) + p.resolver.get_stat("counter_window_good_ms", 0.0)
		var has_d: bool = inp.deflect >= 0.0
		var offset: float = inp.deflect - float(roast.punch) if has_d else 0.0
		if p.peer_id == int(roast.target):
			var r := RoastJudge.judge(cat, str(inp.counter), has_d, offset, perfect_ms, good_ms, p.assist)
			primary_result = r
			results[p.peer_id] = {"result": r, "offset": offset, "role": "primary"}
			_apply_player_outcome(p, r, line)
		elif has_d or str(inp.counter) != "":
			var rb := RoastJudge.judge_backup(cat, str(inp.counter), has_d, offset, perfect_ms, good_ms, p.assist)
			var ok := rb == RoastJudge.PERFECT or rb == RoastJudge.GOOD
			if ok:
				backups += 1
			else:
				p.server_add_morale(float(line.morale_damage) * 0.5)
			results[p.peer_id] = {"result": rb, "offset": offset, "role": "backup", "ok": ok}
	# Boss side.
	var ratiod := false
	var w := RoastJudge.damage_window(primary_result, backups)
	match primary_result:
		RoastJudge.PERFECT:
			perfect_streak += 1
			hype = max(0, hype - 1)
			if perfect_streak >= RoastJudge.RATIOD_STREAK:
				ratiod = true
				perfect_streak = 0
				mode = "stunned"
				stun_left = RoastJudge.RATIOD_STUN_S
				w = {"duration_s": RoastJudge.RATIOD_STUN_S, "mult": RoastJudge.RATIOD_MULT}
				director.skip_next = true
		RoastJudge.GOOD:
			perfect_streak = 0
		RoastJudge.ROASTED:
			perfect_streak = 0
			hype += 1
		_:
			perfect_streak = 0
	if mode != "stunned":
		mode = "assault"
	if float(w.duration_s) > 0.0:
		var dur := float(w.duration_s)
		var target_p := arena.player_by_peer(int(roast.target))
		if target_p:
			dur = target_p.resolver.get_stat("damage_window_duration", dur)
		window_left = dur
		window_mult_v = float(w.mult)
	_roast_result_rpc.rpc(int(roast.uid), results, primary_result, window_left, window_mult_v, ratiod, hype)
	roast = {}
	if hype >= int(def.hype_max):
		_hype_cycle()


func _apply_player_outcome(p: Player, r: String, line: Dictionary) -> void:
	var o: Dictionary = RoastJudge.OUTCOMES[r]
	match r:
		RoastJudge.PERFECT, RoastJudge.GOOD:
			p.server_add_morale(float(o.morale))
			p.server_add_ult(float(o.ult))
			CombatBus.emit_event("on_counter_success", p.peer_id, {"result": r})
			if r == RoastJudge.PERFECT:
				CombatBus.emit_event("on_counter_perfect", p.peer_id)
		RoastJudge.ROASTED:
			p.server_add_morale(float(line.morale_damage))
			CombatBus.emit_event("on_counter_fail", p.peer_id)


func _hype_cycle() -> void:
	hype = 0
	arena.fx_text_all(center() + Vector3.UP * 3.0, "HYPE CYCLE: ALL-HANDS ALIGNMENT SESSION", "#ff4fd8", 64)
	var n := int(def.hype_cycle_adds)
	for i in n:
		var ang := TAU * i / n
		arena.server_spawn_enemy("hype_intern", global_position + Vector3(cos(ang), 0, sin(ang)) * 9.0)


func _end_roast_ui() -> void:
	if not roast.is_empty():
		_roast_result_rpc.rpc(int(roast.uid), {}, "CANCELLED", 0.0, 1.0, false, hype)
		roast = {}


# =========================================================================================
# Clients
# =========================================================================================

@rpc("authority", "call_local", "reliable")
func _roast_start_rpc(uid: int, line_id: String, target_peer: int, t0_server_ms: float, windup_ms: float) -> void:
	var line := _line_by_id(line_id)
	for p in get_tree().get_nodes_in_group("players"):
		p.set_roast_spotlight(p.peer_id == target_peer)
	if RoastUi.instance:
		var target_p := arena.player_by_peer(target_peer)
		RoastUi.instance.begin(self, uid, line, target_peer, target_p.display_name if target_p else "you", t0_server_ms, windup_ms, float(def.icon_reveal_ms))


@rpc("authority", "call_local", "reliable")
func _roast_result_rpc(uid: int, results: Dictionary, primary: String, window_s: float, mult: float, ratiod: bool, new_hype: int) -> void:
	window_left = window_s
	for p in get_tree().get_nodes_in_group("players"):
		p.set_roast_spotlight(false)
	if RoastUi.instance:
		RoastUi.instance.finish(uid, results, primary, window_s, mult, ratiod, new_hype)


func _line_by_id(id: String) -> Dictionary:
	for l in Data.roast_banks[def.roast_bank].lines:
		if l.id == id:
			return l
	return {}
