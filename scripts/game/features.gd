class_name FeatureSystem
extends Node3D
## Scope Creep Launcher "features" (GDD 4): crafting bench, fishing pond, battle-pass kiosk,
## horse, seasonal event tree. Host runs behaviour; every peer renders the same prop.

var arena: Arena
var _next_id := 1
var _live: Dictionary = {}


func spawn_random(pos: Vector3, scale_f: float, dir: Vector3, shooter: Player) -> void:
	var defs: Dictionary = Data.weapons.SCL.features
	var total := 0.0
	for k in defs:
		total += float(defs[k].weight)
	var r := randf() * total
	var kind: String = defs.keys()[0]
	for k in defs:
		r -= float(defs[k].weight)
		if r <= 0.0:
			kind = k
			break
	spawn(kind, pos, scale_f, dir, shooter)


func spawn(kind: String, pos: Vector3, scale_f: float, dir: Vector3, shooter: Player) -> void:
	var d: Dictionary = Data.weapons.SCL.features[kind]
	var id := _next_id
	_next_id += 1
	pos.y = 0.0
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	var life := float(d.get("duration_s", d.get("fuse_s", 1.0)))
	_live[id] = {"id": id, "kind": kind, "pos": pos, "scale": scale_f, "dir": dir, "t": 0.0, "life": life, "shooter": shooter.peer_id if shooter else 0, "hit": {}}
	_fx_spawn.rpc(id, kind, pos, scale_f, dir, life)


@rpc("authority", "call_local", "reliable")
func _fx_spawn(id: int, kind: String, pos: Vector3, scale_f: float, dir: Vector3, life: float) -> void:
	var root := Node3D.new()
	add_child(root)
	root.global_position = pos
	root.scale = Vector3.ONE * scale_f
	var caption := ""
	match kind:
		"crafting_bench":
			root.add_child(Fx.box(Vector3(1.6, 0.9, 0.8), Color("#8b5a2b"), Vector3(0, 0.45, 0)))
			root.add_child(Fx.sphere(0.15, Color.RED, Vector3(0, 1.0, 0), true))
			caption = "NEW! CRAFTING SYSTEM"
		"fishing_pond":
			var w: Dictionary = Data.weapons.SCL.features.fishing_pond
			root.add_child(Fx.cylinder(float(w.radius_m), 0.05, Color("#2f8cff"), Vector3(0, 0.03, 0), 0.6))
			caption = "NEW! FISHING MINIGAME"
		"battle_pass_kiosk":
			root.add_child(Fx.box(Vector3(1.2, 2.2, 0.8), Color("#ffd23f"), Vector3(0, 1.1, 0), true))
			caption = "BATTLE PASS S7: ONLY 950 CRUSADER COINS"
		"horse":
			root.add_child(Fx.box(Vector3(0.7, 0.8, 2.0), Color("#7a4a21"), Vector3(0, 1.2, 0)))
			root.add_child(Fx.box(Vector3(0.45, 0.7, 0.6), Color("#7a4a21"), Vector3(0, 1.8, -1.1)))
			for x in [-0.25, 0.25]:
				for z in [-0.7, 0.7]:
					root.add_child(Fx.box(Vector3(0.15, 0.8, 0.15), Color("#5a3416"), Vector3(x, 0.4, z)))
			root.look_at(pos + dir, Vector3.UP)
			caption = "NEW! HORSE"
		"seasonal_event_tree":
			root.add_child(Fx.cone(1.2, 2.8, Color("#1f9d55"), Vector3(0, 1.6, 0)))
			root.add_child(Fx.sphere(0.2, Color("#ffd23f"), Vector3(0, 3.1, 0), true))
			var tw: Dictionary = Data.weapons.SCL.features.seasonal_event_tree
			root.add_child(Fx.cylinder(float(tw.radius_m), 0.04, Color("#7dff6b"), Vector3(0, 0.03, 0), 0.25))
			caption = "LIMITED-TIME HOLIDAY EVENT"
	var l := Fx.label(caption, Color("#ffffff"), Vector3(0, 3.4, 0), 32)
	root.add_child(l)
	if multiplayer.is_server() and _live.has(id):
		_live[id].node = root
	else:
		_live[id] = {"id": id, "kind": kind, "node": root, "pos": pos, "dir": dir, "t": 0.0, "life": life, "visual_only": true}


@rpc("authority", "call_local", "reliable")
func _fx_end(id: int) -> void:
	var e: Dictionary = _live.get(id, {})
	if e.has("node") and is_instance_valid(e.node):
		if e.kind == "crafting_bench":
			Fx.burst(arena.fx_root, e.node.global_position + Vector3.UP, 4.0 * float(e.node.scale.x), Color("#ff8c1a"), 0.4)
		e.node.queue_free()
	_live.erase(id)


func _physics_process(delta: float) -> void:
	var server := multiplayer.is_server()
	for id in _live.keys():
		var e: Dictionary = _live[id]
		e.t += delta
		if e.kind == "horse" and e.has("node") and is_instance_valid(e.node):
			var spd := float(Data.weapons.SCL.features.horse.speed)
			e.node.global_position += e.dir * spd * delta
			e.pos = e.node.global_position
		if e.get("visual_only", false):
			if e.t > e.life + 1.0 and is_instance_valid(e.get("node")):
				e.node.queue_free()
				_live.erase(id)
			continue
		if not server:
			continue
		_behave(e, delta)
		if e.t >= e.life:
			_finish(e)


func _behave(e: Dictionary, delta: float) -> void:
	var d: Dictionary = Data.weapons.SCL.features[e.kind]
	var s := float(e.scale)
	var shooter: Player = arena.player_by_peer(int(e.shooter))
	var w: Dictionary = Data.weapons.SCL
	match e.kind:
		"fishing_pond":
			for en in arena.enemies():
				if en.global_position.distance_to(e.pos) <= float(d.radius_m) * s:
					en.status["slowed"] = 0.3
		"battle_pass_kiosk":
			for en in arena.enemies():
				if en.team == "enemy" and en.global_position.distance_to(e.pos) <= float(d.lure_radius_m) * s:
					en.server_distract(e.pos, 0.4)
		"seasonal_event_tree":
			for p in arena.alive_players():
				if p.global_position.distance_to(e.pos) <= float(d.radius_m) * s:
					p.server_heal(float(d.heal_per_s) * delta)
		"horse":
			for en in arena.enemies() + arena.bosses():
				if e.hit.has(en.name) or not en.is_alive():
					continue
				if en.global_position.distance_to(e.pos) <= float(d.hit_radius_m) * s + 0.5:
					e.hit[en.name] = true
					if shooter:
						arena.combat.apply_hit(shooter, w, en, false, float(d.damage), en.center(), {"no_crit": true})
					if en is Enemy and en.is_alive():
						en.server_ragdoll(e.dir * 10.0, 0.6, 20.0, shooter)


func _finish(e: Dictionary) -> void:
	if e.kind == "crafting_bench":
		var d: Dictionary = Data.weapons.SCL.features.crafting_bench
		var shooter: Player = arena.player_by_peer(int(e.shooter))
		arena.combat.aoe(shooter, Data.weapons.SCL, e.pos + Vector3.UP, float(d.radius_m) * float(e.scale), float(d.damage))
	_fx_end.rpc(e.id)
