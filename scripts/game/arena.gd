class_name Arena
extends Node3D
## Studio 1, Zone A: The Open-Plan Loft (GDD 3). Builds the placeholder level, owns the
## replicated spawners, runs the wave/boss flow on the host and relays one-shot effects.

signal flow_changed(flow: String, wave: int, text: String)
signal victory

static var current: Arena = null

var level: Dictionary
var players_root: Node3D
var enemies_root: Node3D
var boss_root: Node3D
var fx_root: Node3D
var world_fx: Node3D
var combat: Combat
var projectiles: ProjectileSystem
var features: FeatureSystem
var player_spawner: MultiplayerSpawner
var enemy_spawner: MultiplayerSpawner
var boss_spawner: MultiplayerSpawner
var overview_camera: Camera3D

# Flow (host decides, everyone mirrors).
var flow := "menu"          # menu | warmup | wave | intermission | boss | shipped
var wave := 0
var flow_text := ""
var running := false

# Host-only.
var _flow_timer := 0.0
var _spawn_queue: Array = []
var _spawn_timer := 0.0
var _next_enemy_id := 1
var _profiles: Dictionary = {}
var _walls: Dictionary = {}       # id -> {expire, args}
var _zones: Dictionary = {}       # id -> {pos, radius, slow, morale, expire, args}
var _notes: Array = []            # sticky notes
var _snacks: Array = []           # [{pos, active, respawn}]
var _next_fx_id := 1

# Local visuals keyed by id.
var _wall_nodes: Dictionary = {}
var _zone_nodes: Dictionary = {}
var _note_nodes: Dictionary = {}
var _snack_nodes: Array = []
var _doc_nodes: Dictionary = {}


func _init() -> void:
	current = self


func _ready() -> void:
	level = Data.level()
	_build_level()
	players_root = _child_node("Players")
	enemies_root = _child_node("Enemies")
	boss_root = _child_node("BossRoot")
	fx_root = _child_node("Fx")
	world_fx = _child_node("WorldFx")
	combat = Combat.new()
	combat.name = "Combat"
	combat.arena = self
	add_child(combat)
	projectiles = ProjectileSystem.new()
	projectiles.name = "Projectiles"
	projectiles.arena = self
	add_child(projectiles)
	features = FeatureSystem.new()
	features.name = "Features"
	features.arena = self
	add_child(features)
	player_spawner = _make_spawner("PlayerSpawner", "../Players", _spawn_player)
	enemy_spawner = _make_spawner("EnemySpawner", "../Enemies", _spawn_enemy)
	boss_spawner = _make_spawner("BossSpawner", "../BossRoot", _spawn_boss)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _child_node(n: String) -> Node3D:
	var x := Node3D.new()
	x.name = n
	add_child(x)
	return x


func _make_spawner(n: String, path: String, fn: Callable) -> MultiplayerSpawner:
	var s := MultiplayerSpawner.new()
	s.name = n
	s.spawn_function = fn
	add_child(s)
	s.spawn_path = NodePath(path)
	return s


# =========================================================================================
# Queries
# =========================================================================================

func players() -> Array:
	var out: Array = []
	for p in players_root.get_children():
		if p is Player and not p.is_queued_for_deletion():
			out.append(p)
	return out


func alive_players() -> Array:
	return players().filter(func(p): return not p.downed)


func enemies() -> Array:
	var out: Array = []
	for e in enemies_root.get_children():
		if e is Enemy and e.is_alive() and not e.is_queued_for_deletion():
			out.append(e)
	return out


func bosses() -> Array:
	var out: Array = []
	for b in boss_root.get_children():
		if b is Boss and b.is_alive() and not b.is_queued_for_deletion():
			out.append(b)
	return out


func boss() -> Boss:
	var b := bosses()
	return b[0] if not b.is_empty() else null


func boss_window_open() -> bool:
	var b := boss()
	return b != null and b.in_window()


func player_by_peer(peer: int) -> Player:
	return players_root.get_node_or_null("P_%d" % peer) as Player


func enemy_by_name(n: String) -> Enemy:
	return enemies_root.get_node_or_null(n) as Enemy


func player_spawn_point(peer: int) -> Vector3:
	var pts: Array = level.player_spawns
	return JsonUtil.vec3(pts[(peer if peer > 1 else 0) % pts.size()]) + Vector3.UP * 0.2


# =========================================================================================
# Session start / registration
# =========================================================================================

func start_server_game() -> void:
	running = true
	_reset_world_state()
	_register(1, Game.profile_for_host())
	_set_flow_server("warmup", 0, "Clock in. Waves start soon. [Tab] Toolset tree")
	_flow_timer = float(level.warmup_s)


func start_client() -> void:
	running = true
	_srv_register.rpc_id(1, Game.profile_for_host())


@rpc("any_peer", "reliable")
func _srv_register(profile: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	if str(profile.get("content_hash", "")) != Data.content_hash():
		_kicked.rpc_id(peer, "Game data mismatch with host. Update to the same build.")
		get_tree().create_timer(0.5).timeout.connect(func(): multiplayer.multiplayer_peer.disconnect_peer(peer))
		return
	if players().size() >= Net.max_players():
		_kicked.rpc_id(peer, "Lobby is full.")
		return
	_register(peer, profile)
	_sync_world_to(peer)


@rpc("authority", "reliable")
func _kicked(reason: String) -> void:
	Net.session_ended.emit(reason)


func _register(peer: int, profile: Dictionary) -> void:
	_profiles[peer] = profile
	var name_s := str(profile.get("name", "Crusader")).strip_edges()
	if name_s.is_empty():
		name_s = "Crusader"
	player_spawner.spawn({"peer": peer, "name": name_s, "pos": player_spawn_point(peer)})
	var p := player_by_peer(peer)
	if p:
		p.server_setup(profile)
	fx_text_all(player_spawn_point(peer) + Vector3.UP * 2.5, "%s clocked in" % name_s, "#7cf7ff")


func _spawn_player(data: Dictionary) -> Node:
	return Player.create(int(data.peer), str(data.name), data.pos)


func _spawn_enemy(data: Dictionary) -> Node:
	return Enemy.create(int(data.id), str(data.type), data.pos, float(data.hp_mult))


func _spawn_boss(data: Dictionary) -> Node:
	return Boss.create(data.pos, float(data.hp_mult))


func _on_peer_disconnected(peer: int) -> void:
	if not multiplayer.is_server():
		return
	var p := player_by_peer(peer)
	if p:
		fx_text_all(p.global_position + Vector3.UP * 2.0, "%s left (contract ended)" % p.display_name, "#ffb347")
		p.queue_free()
	_profiles.erase(peer)


func send_flow_to(peer: int) -> void:
	_set_flow.rpc_id(peer, flow, wave, flow_text)


# =========================================================================================
# Host: flow
# =========================================================================================

func _physics_process(delta: float) -> void:
	if not running or not multiplayer.is_server():
		return
	_tick_flow(delta)
	_tick_world(delta)


func _tick_flow(delta: float) -> void:
	_flow_timer -= delta
	match flow:
		"warmup", "intermission":
			if _flow_timer <= 0.0:
				if Game.args.get("start", "") == "boss" or wave >= level.waves.size():
					_start_boss()
				else:
					_start_wave(wave + 1)
		"wave":
			_spawn_timer -= delta
			if not _spawn_queue.is_empty() and _spawn_timer <= 0.0:
				_spawn_timer = float(level.spawn_interval_s)
				var t: String = _spawn_queue.pop_front()
				var pts: Array = level.enemy_spawns
				server_spawn_enemy(t, JsonUtil.vec3(pts.pick_random()) + Vector3(randf_range(-1.5, 1.5), 0.3, randf_range(-1.5, 1.5)))
			if _spawn_queue.is_empty() and enemies().is_empty():
				_set_flow_server("intermission", wave, "Wave cleared. Snacks are in the break room.")
				_flow_timer = float(level.intermission_s)
		"shipped":
			if _flow_timer <= 0.0:
				_reset_world_state()
				wave = 0
				_set_flow_server("warmup", 0, "New sprint. Same studio.")
				_flow_timer = float(level.warmup_s)


func _start_wave(n: int) -> void:
	wave = n
	var w: Dictionary = level.waves[n - 1]
	_spawn_queue.clear()
	var pc := players().size()
	for t in w.spawns:
		for i in CoopScaling.scaled_count(int(w.spawns[t]), pc):
			_spawn_queue.append(t)
	_spawn_queue.shuffle()
	_spawn_timer = 0.0
	_set_flow_server("wave", n, "Wave %d/%d: %s" % [n, level.waves.size(), w.name_en])


func _start_boss() -> void:
	for e in enemies():
		e.queue_free()
	_spawn_queue.clear()
	boss_spawner.spawn({"pos": JsonUtil.vec3(level.boss_spawn) + Vector3.UP * 0.2, "hp_mult": CoopScaling.boss_hp_mult(players().size())})
	_set_flow_server("boss", wave, "BOSS: Facilitator Prime. Counter its roasts! [1-4] pick, [E]/RMB deflect")


func server_spawn_enemy(type: String, pos: Vector3) -> void:
	if not Data.enemies.has(type):
		push_error("Unknown enemy type %s" % type)
		return
	var id := _next_enemy_id
	_next_enemy_id += 1
	enemy_spawner.spawn({"id": id, "type": type, "pos": pos, "hp_mult": CoopScaling.enemy_hp_mult(players().size())})


func _set_flow_server(f: String, w: int, text: String) -> void:
	_set_flow.rpc(f, w, text)


@rpc("authority", "call_local", "reliable")
func _set_flow(f: String, w: int, text: String) -> void:
	flow = f
	wave = w
	flow_text = text
	flow_changed.emit(f, w, text)


func boss_context(tag: String) -> void:
	var b := boss()
	if b:
		b.director.notify_context(tag)


# =========================================================================================
# Host: combat callbacks
# =========================================================================================

func damage_player(p: Player, hp_dmg: float, morale_dmg: float, source: String) -> void:
	p.server_take_damage(hp_dmg, morale_dmg, source)


func on_enemy_killed(e: Enemy, killer: Player, weapon_id: String) -> void:
	var credits := int(e.def.get("credits", 0))
	var share_r := float(level.get("kill_credit_share_radius_m", 25.0))
	for p in players():
		if p == killer or p.global_position.distance_to(e.global_position) <= share_r:
			p.toolset.add_currency("studio_credits", credits)
			p._dirty = true
	if killer:
		killer.server_add_morale(MoraleRules.KILL_RELIEF)
		killer.server_add_ult(Player.ULT_KILL_CHARGE)
		CombatBus.emit_event("on_kill", killer.peer_id, {"enemy": e.type_id, "weapon": weapon_id})
		combat.run_triggers(killer, "on_kill", {"target": e})
		if weapon_id == "HFS":
			combat.maybe_regress(e.global_position, Data.weapons.HFS)
	_fx_enemy_death.rpc(e.type_id, e.center(), str(e.def.get("death_banner", "")), credits)


func on_boss_defeated(b: Boss) -> void:
	var rw: Dictionary = b.def.rewards
	for p in players():
		p.toolset.add_currency("studio_credits", int(rw.studio_credits))
		p.toolset.add_currency("keystone_tokens", int(rw.keystone_tokens))
		p.toolset.add_currency("industry_knowledge", int(rw.industry_knowledge))
		p.milestone = max(p.milestone, 1)
		p._send_toolset()
		p._dirty = true
	_fx_confetti.rpc(b.center(), 400)
	_victory.rpc(b.global_position)
	_set_flow_server("shipped", wave, "MILESTONE_1_SHIPPED. Saccharine Toddler Inc. is patched.")
	_flow_timer = 20.0


func on_projectile_impact(e: Dictionary, pos: Vector3, target: Variant) -> void:
	var pl: Dictionary = e.payload
	if e.team == "enemy":
		if target is Player:
			damage_player(target, float(pl.get("damage", 0.0)), float(pl.get("morale", 0.0)), str(pl.get("source", "")))
			if pl.has("status"):
				target.server_set_status(str(pl.status), float(pl.status_s))
		return
	if e.kind == "scope_creep":
		var shooter := player_by_peer(int(pl.shooter))
		var w: Dictionary = Data.weapons[pl.weapon]
		var s := float(pl.scale)
		if shooter:
			combat.aoe(shooter, w, pos, float(w.aoe_radius_m) * s, float(w.damage))
		fx_burst_all(pos, float(w.aoe_radius_m) * s, "#c38bff")
		features.spawn_random(pos, s, pl.dir, shooter)


func server_interact(p: Player) -> void:
	var cm := JsonUtil.vec3(level.coffee_machine)
	if p.global_position.distance_to(cm) <= Player.INTERACT_RANGE_M:
		var now := Time.get_ticks_msec() / 1000.0
		p.coffee_times = p.coffee_times.filter(func(t): return now - t < 60.0)
		p.coffee_times.append(now)
		p.server_add_morale(MoraleRules.COFFEE_RELIEF)
		if p.coffee_times.size() >= 3:
			p.jitter_left = 10.0
			p.server_set_status("jitters", 10.0)
			p.client_toast.rpc_id(p.peer_id, "JITTERS: aim sway, +20% fire rate", "#ffb347")
		else:
			p.client_toast.rpc_id(p.peer_id, "Coffee: -25 Morale", "#c69c6d")
		return
	for d in level.design_docs:
		if p.global_position.distance_to(JsonUtil.vec3(d.pos)) <= Player.INTERACT_RANGE_M and not p.docs_read.has(d.id):
			p.docs_read.append(d.id)
			p.toolset.add_currency("industry_knowledge", int(d.industry_knowledge))
			p._send_toolset()
			p.client_toast.rpc_id(p.peer_id, "DESIGN DOC (+%d Industry Knowledge): %s" % [int(d.industry_knowledge), d.text_en], "#ffffff")
			_fx_doc_read.rpc_id(p.peer_id, str(d.id))
			return


# =========================================================================================
# Host: temporary walls, zones, sticky notes, pickups
# =========================================================================================

func spawn_wall(pos: Vector3, size: Vector3, yaw: float, color: String, caption: String, dur: float) -> String:
	var id := "W%d" % _next_fx_id
	_next_fx_id += 1
	var args := [id, pos, size, yaw, color, caption]
	_walls[id] = {"expire": dur, "args": args}
	_fx_wall.rpc(id, pos, size, yaw, color, caption)
	return id


func remove_wall(id: String) -> void:
	if _walls.has(id):
		_walls.erase(id)
		_fx_wall_remove.rpc(id)


func spawn_zone(pos: Vector3, radius: float, color: String, slow: float, morale_per_s: float, dur: float) -> String:
	var id := "Z%d" % _next_fx_id
	_next_fx_id += 1
	pos.y = 0.0
	_zones[id] = {"pos": pos, "radius": radius, "slow": slow, "morale": morale_per_s, "expire": dur, "args": [id, pos, radius, color]}
	_fx_zone.rpc(id, pos, radius, color)
	return id


func remove_zone(id: String) -> void:
	if _zones.has(id):
		_zones.erase(id)
		_fx_zone_remove.rpc(id)


func spawn_sticky_note(pos: Vector3, radius: float, arm_s: float, root_s: float, life_s: float) -> void:
	var id := "N%d" % _next_fx_id
	_next_fx_id += 1
	pos.y = 0.02
	_notes.append({"id": id, "pos": pos, "radius": radius, "arm": arm_s, "root": root_s, "life": life_s})
	_fx_note.rpc(id, pos, radius)


func _tick_world(delta: float) -> void:
	for id in _walls.keys():
		_walls[id].expire -= delta
		if _walls[id].expire <= 0.0:
			remove_wall(id)
	for id in _zones.keys():
		var z: Dictionary = _zones[id]
		z.expire -= delta
		if z.expire <= 0.0:
			remove_zone(id)
			continue
		for p in alive_players():
			if p.global_position.distance_to(z.pos) <= z.radius:
				p.server_add_morale(z.morale * delta)
				if z.slow > 0.0 and Engine.get_physics_frames() % 10 == 0:
					p.server_set_status("slowed", 0.3)
	for n in _notes.duplicate():
		n.arm -= delta
		n.life -= delta
		var consumed := false
		if n.arm <= 0.0:
			for p in alive_players():
				if p.global_position.distance_to(n.pos) <= n.radius:
					p.server_set_status("rooted", n.root)
					fx_text_all(p.global_position + Vector3.UP * 2.2, "PARKED", "#ffe74c")
					consumed = true
					break
		if consumed or n.life <= 0.0:
			_notes.erase(n)
			_fx_note_remove.rpc(n.id)
	for i in _snacks.size():
		var s: Dictionary = _snacks[i]
		if not s.active:
			s.respawn -= delta
			if s.respawn <= 0.0:
				s.active = true
				_fx_snack.rpc(i, true)
			continue
		for p in alive_players():
			if p.hp < p.max_hp and p.global_position.distance_to(s.pos) <= 1.4:
				p.server_heal(float(level.snack_heal))
				s.active = false
				s.respawn = float(level.snack_respawn_s)
				_fx_snack.rpc(i, false)
				p.client_toast.rpc_id(p.peer_id, "Snack: +%d HP" % int(level.snack_heal), "#7dff6b")
				break


func _reset_world_state() -> void:
	for id in _walls.keys():
		remove_wall(id)
	for id in _zones.keys():
		remove_zone(id)
	for n in _notes:
		_fx_note_remove.rpc(n.id)
	_notes.clear()
	_snacks.clear()
	for s in level.snacks:
		_snacks.append({"pos": JsonUtil.vec3(s), "active": true, "respawn": 0.0})
	for b in boss_root.get_children():
		b.queue_free()
	for e in enemies_root.get_children():
		e.queue_free()


## Late joiners get the current temporary geometry (spawners already replay players/enemies).
func _sync_world_to(peer: int) -> void:
	send_flow_to(peer)
	for id in _walls:
		var a: Array = _walls[id].args
		_fx_wall.rpc_id(peer, a[0], a[1], a[2], a[3], a[4], a[5])
	for id in _zones:
		var a: Array = _zones[id].args
		_fx_zone.rpc_id(peer, a[0], a[1], a[2], a[3])
	for i in _snacks.size():
		if not _snacks[i].active:
			_fx_snack.rpc_id(peer, i, false)


# =========================================================================================
# Effects on every peer
# =========================================================================================

func fx_text_all(pos: Vector3, text: String, color: String, size := 48) -> void:
	_fx_text.rpc(pos, text, color, size)


func fx_burst_all(pos: Vector3, radius: float, color: String) -> void:
	_fx_burst.rpc(pos, radius, color)


func fx_tracer_all(from: Vector3, to: Vector3, color: String) -> void:
	_fx_tracers.rpc(from, [to], color)


func fx_tracers_all(from: Vector3, ends: Array, color: String) -> void:
	_fx_tracers.rpc(from, ends, color)


func fx_confetti_all(pos: Vector3, amount: int) -> void:
	_fx_confetti.rpc(pos, amount)


@rpc("authority", "call_local", "unreliable")
func _fx_text(pos: Vector3, text: String, color: String, size: int) -> void:
	Fx.float_text(fx_root, pos, text, Color(color), size, 1.8, 1.4)


@rpc("authority", "call_local", "unreliable")
func _fx_burst(pos: Vector3, radius: float, color: String) -> void:
	Fx.burst(fx_root, pos, radius, Color(color))


@rpc("authority", "call_local", "unreliable")
func _fx_tracers(from: Vector3, ends: Array, color: String) -> void:
	for e in ends:
		Fx.tracer(fx_root, from, e, Color(color))


@rpc("authority", "call_local", "unreliable")
func _fx_confetti(pos: Vector3, amount: int) -> void:
	Fx.confetti(fx_root, pos, amount, 1.5)


@rpc("authority", "call_local", "reliable")
func _fx_enemy_death(type: String, pos: Vector3, banner: String, credits: int) -> void:
	Fx.confetti(fx_root, pos, 50 if type == "hype_intern" else 25)
	if banner != "":
		Fx.float_text(fx_root, pos + Vector3.UP * 0.8, banner, Color("#ffd23f"), 52, 1.8, 1.8)
	Fx.float_text(fx_root, pos, "+%d SC" % credits, Color("#7dff6b"), 32, 1.2, 1.0)


@rpc("authority", "call_local", "reliable")
func _victory(pos: Vector3) -> void:
	Fx.confetti(fx_root, pos + Vector3.UP * 2.0, 400, 2.0)
	victory.emit()


@rpc("authority", "call_local", "reliable")
func _fx_wall(id: String, pos: Vector3, size: Vector3, yaw: float, color: String, caption: String) -> void:
	if _wall_nodes.has(id):
		return
	var w := Fx.static_box(size, Color(color), pos)
	w.rotation.y = yaw
	var l := Fx.label(caption, Color("#111111"), Vector3(0, 0.0, 0.25), 64)
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	w.add_child(l)
	var l2 := l.duplicate()
	l2.position.z = -0.25
	l2.rotation_degrees.y = 180
	w.add_child(l2)
	world_fx.add_child(w)
	_wall_nodes[id] = w


@rpc("authority", "call_local", "reliable")
func _fx_wall_remove(id: String) -> void:
	if _wall_nodes.has(id):
		var w: Node3D = _wall_nodes[id]
		Fx.burst(fx_root, w.global_position, 1.5, Color("#ffffff"), 0.2)
		w.queue_free()
		_wall_nodes.erase(id)


@rpc("authority", "call_local", "reliable")
func _fx_zone(id: String, pos: Vector3, radius: float, color: String) -> void:
	var z := Fx.cylinder(radius, 0.06, Color(color), pos + Vector3.UP * 0.04, 0.7)
	world_fx.add_child(z)
	_zone_nodes[id] = z


@rpc("authority", "call_local", "reliable")
func _fx_zone_remove(id: String) -> void:
	if _zone_nodes.has(id):
		_zone_nodes[id].queue_free()
		_zone_nodes.erase(id)


@rpc("authority", "call_local", "reliable")
func _fx_note(id: String, pos: Vector3, radius: float) -> void:
	var n := Fx.box(Vector3(radius * 1.4, 0.04, radius * 1.4), Color("#ffe74c"), pos, true)
	n.rotation.y = randf() * TAU
	var l := Fx.label("PARKING LOT", Color("#333333"), Vector3(0, 0.6, 0), 28)
	n.add_child(l)
	world_fx.add_child(n)
	_note_nodes[id] = n


@rpc("authority", "call_local", "reliable")
func _fx_note_remove(id: String) -> void:
	if _note_nodes.has(id):
		_note_nodes[id].queue_free()
		_note_nodes.erase(id)


@rpc("authority", "call_local", "reliable")
func _fx_snack(i: int, active: bool) -> void:
	if i < _snack_nodes.size():
		_snack_nodes[i].visible = active


@rpc("authority", "call_local", "reliable")
func _fx_doc_read(id: String) -> void:
	if _doc_nodes.has(id):
		_doc_nodes[id].visible = false


# =========================================================================================
# Level geometry (placeholder primitives)
# =========================================================================================

func _build_level() -> void:
	var geo := Node3D.new()
	geo.name = "Level"
	add_child(geo)
	var sx := float(level.size_m[0])
	var sz := float(level.size_m[1])
	var wh := float(level.wall_height_m)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#2b2140")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#d8d0ff")
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	env.environment = e
	geo.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	geo.add_child(sun)
	for x in [-12.0, 0.0, 12.0]:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(x, wh - 1.0, 0)
		lamp.omni_range = 18.0
		lamp.light_color = Color("#ffe8c2")
		geo.add_child(lamp)

	# Floor (polished concrete) and walls (exposed brick).
	geo.add_child(Fx.static_box(Vector3(sx, 1.0, sz), Color("#8d8a92"), Vector3(0, -0.5, 0)))
	for side in [[Vector3(sx, wh, 1), Vector3(0, wh / 2, -sz / 2)], [Vector3(sx, wh, 1), Vector3(0, wh / 2, sz / 2)],
			[Vector3(1, wh, sz), Vector3(-sx / 2, wh / 2, 0)], [Vector3(1, wh, sz), Vector3(sx / 2, wh / 2, 0)]]:
		geo.add_child(Fx.static_box(side[0], Color("#9c4f3c"), side[1]))
	for x in range(-18, 19, 6):  # exposed beams
		geo.add_child(Fx.box(Vector3(0.4, 0.5, sz), Color("#3b2a20"), Vector3(x, wh - 0.3, 0)))

	# Banners: the studio is a "passion collective".
	var signs := [
		["SACCHARINE TODDLER INC.", Vector3(0, 5.0, -sz / 2 + 0.6), 0.0],
		["STORY ALIGNMENT PASSES: NOW ON SUBSCRIPTION", Vector3(-sx / 2 + 0.6, 4.5, 0), PI / 2],
		["FONT DEBATE: DAY 400", Vector3(sx / 2 - 0.6, 4.5, 0), -PI / 2],
		["BREAK ROOM", Vector3(-17, 3.6, sz / 2 - 0.6), PI],
	]
	for s in signs:
		var l := Fx.label(s[0], Color("#ff4fd8"), s[1], 96)
		l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		l.rotation.y = s[2]
		geo.add_child(l)

	# Standing desks in pods, beanbags, pillars: cover for the arena.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for pod in [Vector3(-11, 0, -7), Vector3(11, 0, -7), Vector3(-11, 0, 6), Vector3(11, 0, 6)]:
		for i in 3:
			var p: Vector3 = pod + Vector3((i - 1) * 2.4, 0, 0)
			geo.add_child(Fx.static_box(Vector3(2.0, 1.1, 1.0), Color("#e9e2d0"), p + Vector3(0, 0.55, 0)))
			geo.add_child(Fx.box(Vector3(0.6, 0.4, 0.05), Color("#1a1a1a"), p + Vector3(0, 1.35, 0.1)))
	for i in 8:
		var bp := Vector3(rng.randf_range(-16, 16), 0.45, rng.randf_range(-13, 13))
		if bp.length() < 6.0:
			continue
		var bag := StaticBody3D.new()
		bag.collision_layer = Layers.WORLD
		bag.position = bp
		var cs := CollisionShape3D.new()
		var sp := SphereShape3D.new()
		sp.radius = 0.75
		cs.shape = sp
		bag.add_child(cs)
		bag.add_child(Fx.sphere(0.75, Color.from_hsv(rng.randf(), 0.6, 0.9)))
		geo.add_child(bag)
	for p in [Vector3(-6, 0, -2), Vector3(6, 0, -2), Vector3(-6, 0, 10), Vector3(6, 0, 10)]:
		geo.add_child(Fx.static_box(Vector3(1.0, wh, 1.0), Color("#5d5d66"), p + Vector3(0, wh / 2, 0)))

	# Break room: coffee machine, snacks.
	var cm := JsonUtil.vec3(level.coffee_machine)
	geo.add_child(Fx.static_box(Vector3(0.9, 1.6, 0.7), Color("#2d2d2d"), cm + Vector3(0, 0.8, 0)))
	geo.add_child(Fx.label("COFFEE [F]", Color("#c69c6d"), cm + Vector3(0, 2.1, 0), 40))
	for s in level.snacks:
		var n := Fx.box(Vector3(0.5, 0.35, 0.3), Color("#ffb347"), JsonUtil.vec3(s) + Vector3(0, 0.6, 0), true)
		n.add_child(Fx.label("SNACK", Color("#ffb347"), Vector3(0, 0.5, 0), 28))
		geo.add_child(n)
		_snack_nodes.append(n)
	for d in level.design_docs:
		var doc := Fx.box(Vector3(0.4, 0.05, 0.55), Color("#ffffff"), JsonUtil.vec3(d.pos) + Vector3(0, 0.9, 0), true)
		doc.add_child(Fx.label("DESIGN DOC [F]", Color("#ffffff"), Vector3(0, 0.45, 0), 28))
		geo.add_child(doc)
		_doc_nodes[str(d.id)] = doc

	overview_camera = Camera3D.new()
	overview_camera.position = Vector3(0, 18, 24)
	overview_camera.rotation_degrees = Vector3(-38, 0, 0)
	geo.add_child(overview_camera)
	overview_camera.current = true
