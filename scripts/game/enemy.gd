class_name Enemy
extends CharacterBody3D
## Data-driven enemy (data/enemies/enemies.json). AI and damage run on the host only;
## clients render the replicated position/state.

const GRAVITY := 20.0

var enemy_id := 0
var type_id := ""
var def: Dictionary = {}
var arena: Arena

# Replicated (host -> clients).
var sync_pos := Vector3.ZERO
var sync_yaw := 0.0
var hp := 1.0
var max_hp := 1.0
var state := "active"     # active | stunned | ragdoll | ally | distracted | dead
var aux := 0.0            # billing meter (Messaging Consultant)
var regressed := false

# Host-only.
var team := "enemy"
var status: Dictionary = {}   # stunned, ragdoll, ally, distracted, slowed, regressed, flinch -> seconds left
var attack_cd := 0.0
var special_cd := 0.0
var bark_cd := 0.0
var distract_pos := Vector3.ZERO
var ragdoll_vel := Vector3.ZERO
var ragdoll_hit: Dictionary = {}
var ragdoll_source: Player = null
var dialogue_owner := 0
var summoned := false
var barrier_ids: Array = []
var _strafe := 1.0

# Visuals.
var visual: Node3D
var overhead: Label3D
var weak_area: Area3D
var _flash_t := 0.0


static func create(id: int, type: String, pos: Vector3, hp_mult: float) -> Enemy:
	var e := Enemy.new()
	e.enemy_id = id
	e.type_id = type
	e.name = "E_%d" % id
	e.def = Data.enemies[type]
	e.position = pos
	e.sync_pos = pos
	e.max_hp = float(e.def.hp) * hp_mult
	e.hp = e.max_hp
	e._build()
	return e


func _build() -> void:
	collision_layer = Layers.ENEMY
	collision_mask = Layers.WORLD
	var v: Dictionary = def.get("visual", {})
	var h := float(v.get("height", 1.7))
	var r := float(v.get("radius", 0.4))
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = h
	shape.shape = cap
	shape.position = Vector3(0, h * 0.5, 0)
	add_child(shape)
	set_meta("hit_owner", self)

	visual = Node3D.new()
	add_child(visual)
	var body_col := JsonUtil.color(str(v.get("body", "")), Color.MAGENTA)
	var head_col := JsonUtil.color(str(v.get("head", "")), Color.WHITE)
	visual.add_child(Fx.capsule(r, h * 0.8, body_col, Vector3(0, h * 0.4, 0)))
	visual.add_child(Fx.box(Vector3(r * 1.3, r * 1.1, r * 1.3), head_col, Vector3(0, h * 0.88, 0)))
	visual.add_child(Fx.box(Vector3(r * 0.9, 0.08, 0.05), Color("#111111"), Vector3(0, h * 0.9, -r * 0.66)))
	match type_id:
		"hype_intern":
			for i in 3:  # lanyards stacked six deep (three is enough for placeholder art)
				visual.add_child(Fx.box(Vector3(0.06, 0.45, 0.02), Color.from_hsv(i * 0.3, 0.8, 1.0), Vector3(-0.1 + i * 0.1, h * 0.55, -r - 0.02)))
		"messaging_consultant", "partner":
			visual.add_child(Fx.box(Vector3(0.5, 0.35, 0.05), Color("#ffffff"), Vector3(0.45, h * 0.55, -0.2)))  # slide deck
		"compliance_officer":
			visual.add_child(Fx.box(Vector3(r * 2.2, h * 0.5, r * 1.6), body_col.darkened(0.2), Vector3(0, h * 0.45, 0)))
			var hand := Fx.sphere(0.22, Color("#d12f2f"), Vector3(r + 0.35, h * 0.6, -0.2), true)
			visual.add_child(hand)
			weak_area = Area3D.new()
			weak_area.collision_layer = Layers.HITBOX
			weak_area.collision_mask = 0
			weak_area.monitoring = false
			weak_area.position = hand.position
			var ws := CollisionShape3D.new()
			var sph := SphereShape3D.new()
			sph.radius = 0.32
			ws.shape = sph
			weak_area.add_child(ws)
			weak_area.set_meta("hit_owner", self)
			weak_area.set_meta("weakpoint", true)
			add_child(weak_area)
	overhead = Fx.label("", Color.WHITE, Vector3(0, h + 0.45, 0), 32)
	add_child(overhead)
	Fx.add_sync(self, ["sync_pos", "sync_yaw", "hp", "max_hp", "state", "aux", "regressed"], ["hp", "max_hp", "state", "aux", "regressed"])


func _ready() -> void:
	arena = Arena.current
	add_to_group("enemies")
	attack_cd = randf_range(0.5, 1.5)
	special_cd = randf_range(1.0, 3.0)
	bark_cd = randf_range(2.0, 6.0)


func is_alive() -> bool:
	return state != "dead" and hp > 0.0


func get_target_tags() -> Array:
	var t: Array = ["enemy"] + def.get("tags", [])
	if status.has("distracted"):
		t.append("distracted")
	return t


func window_mult() -> float:
	return 1.0


func current_resist() -> float:
	var r := float(def.get("resist", 0.0))
	if status.has("distracted"):
		r -= float(Data.weapons.SCL.features.battle_pass_kiosk.vulnerability)
	return r


func center() -> Vector3:
	return global_position + Vector3(0, float(def.visual.get("height", 1.7)) * 0.5, 0)


# =========================================================================================

func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_server_ai(delta)
		sync_pos = global_position
		sync_yaw = rotation.y
	else:
		global_position = global_position.lerp(sync_pos, clampf(delta * 12.0, 0.0, 1.0))
		rotation.y = lerp_angle(rotation.y, sync_yaw, clampf(delta * 12.0, 0.0, 1.0))
	_update_visuals(delta)


func _update_visuals(delta: float) -> void:
	_flash_t = max(0.0, _flash_t - delta)
	visual.scale = Vector3.ONE * (1.0 + 0.12 * _flash_t / 0.12)
	var txt := ""
	match state:
		"stunned":
			txt = "[1] Agree  [2] Disagree  [3] Lie"
		"ally":
			txt = "* CONVINCED *"
		"distracted":
			txt = "$ buying battle pass $"
		_:
			if type_id == "messaging_consultant":
				txt = "BILLING $%d%%" % int(aux)
	if regressed:
		txt = "REGRESSED " + txt
	if hp < max_hp:
		txt += "\n" + "|".repeat(int(ceil(10.0 * hp / max_hp))) + ".".repeat(10 - int(ceil(10.0 * hp / max_hp)))
	overhead.text = txt
	overhead.modulate = Color("#7dff6b") if state == "ally" else (Color("#c38bff") if regressed else Color.WHITE)
	visual.rotation.z = 1.4 if state == "ragdoll" else (0.3 * sin(Time.get_ticks_msec() / 80.0) if state == "stunned" else 0.0)


func flash() -> void:
	_flash_t = 0.12


# =========================================================================================
# Host: damage and status
# =========================================================================================

## Returns true when this hit killed the enemy.
func server_damage(amount: float, source: Player, info: Dictionary = {}) -> bool:
	if not is_alive():
		return false
	if state == "ally" and source != null:
		return false  # don't shoot the convinced
	hp -= amount
	_flash_t = 0.12
	if info.get("weakpoint", false) and type_id == "compliance_officer":
		_drop_barriers()
	if hp <= 0.0:
		_die(source, str(info.get("weapon", "")))
		return true
	if status.has("ragdoll") == false and amount > max_hp * 0.25:
		status["flinch"] = 0.2
	return false


func server_stun(seconds: float, owner_peer: int) -> void:
	status["stunned"] = seconds
	dialogue_owner = owner_peer
	state = "stunned"


func server_ragdoll(vel: Vector3, seconds: float, impact_damage: float, source: Player) -> void:
	status.erase("stunned")
	status["ragdoll"] = seconds
	ragdoll_vel = vel
	ragdoll_hit = {"damage": impact_damage}
	ragdoll_source = source
	state = "ragdoll"


func server_turn_ally(seconds: float) -> void:
	status.erase("stunned")
	status["ally"] = seconds
	team = "player"
	state = "ally"


func server_distract(pos: Vector3, seconds: float) -> void:
	if status.has("ally") or status.has("ragdoll"):
		return
	distract_pos = pos
	status["distracted"] = seconds


func server_regress(seconds: float) -> void:
	status["regressed"] = seconds
	regressed = true


func _die(source: Player, weapon_id: String) -> void:
	state = "dead"
	hp = 0.0
	_drop_barriers()
	arena.on_enemy_killed(self, source, weapon_id)
	queue_free()


func _drop_barriers() -> void:
	for id in barrier_ids:
		arena.remove_wall(id)
	barrier_ids.clear()


# =========================================================================================
# Host: AI
# =========================================================================================

func _server_ai(delta: float) -> void:
	if not is_alive():
		return
	for k in status.keys():
		status[k] -= delta
		if status[k] <= 0.0:
			status.erase(k)
			_on_status_end(k)
	if not is_alive():
		return
	attack_cd -= delta
	special_cd -= delta
	bark_cd -= delta
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0
	if status.has("ragdoll"):
		_ragdoll_tick(delta)
		return
	if status.has("stunned") or status.has("flinch"):
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return
	state = "ally" if status.has("ally") else ("distracted" if status.has("distracted") else "active")
	regressed = status.has("regressed")
	if bark_cd <= 0.0 and state == "active":
		bark_cd = randf_range(6.0, 12.0)
		var barks: Array = def.get("barks", [])
		if not barks.is_empty():
			arena.fx_text_all(global_position + Vector3.UP * (float(def.visual.height) + 0.9), barks.pick_random(), "#ffffff", 30)
	var speed := float(def.speed) * (1.3 if regressed else 1.0)
	if status.has("slowed"):
		speed *= 0.4
	if status.has("distracted"):
		_move_to(distract_pos, speed, 1.2)
		return
	var target := _pick_target()
	if target == null:
		_move_to(global_position, 0.0, 0.0)
		return
	var tpos: Vector3 = target.global_position
	var dist := global_position.distance_to(tpos)
	match str(def.ai):
		"swarmer":
			_move_to(tpos, speed, float(def.melee_range_m) * 0.8)
			if dist <= float(def.melee_range_m):
				_try_melee(target)
			elif dist <= float(def.get("ranged_range_m", 0.0)) and special_cd <= 0.0:
				special_cd = float(def.ranged_cooldown_s) * randf_range(0.8, 1.3)
				_shoot(target)
		"caster":
			var band: Array = def.get("preferred_range_m", [9, 14])
			if dist > float(band[1]):
				_move_to(tpos, speed, 0.0)
			elif dist < float(band[0]):
				_move_to(global_position + (global_position - tpos).normalized() * 4.0, speed, 0.0)
			else:
				var side := (tpos - global_position).cross(Vector3.UP).normalized() * _strafe
				if randf() < delta * 0.4:
					_strafe = -_strafe
				_move_to(global_position + side * 3.0, speed * 0.6, 0.0)
				_face(tpos)
			if attack_cd <= 0.0 and dist <= float(def.ranged_range_m):
				attack_cd = float(def.ranged_cooldown_s) * (0.75 if regressed else 1.0)
				_shoot(target)
			if def.has("billing_seconds_to_cap") and state == "active":
				aux = min(100.0, aux + 100.0 / float(def.billing_seconds_to_cap) * delta)
				if aux >= 100.0 and not summoned:
					summoned = true
					aux = 0.0
					arena.server_spawn_enemy(str(def.billing_summon), global_position + Vector3(1.5, 0, 1.5))
					arena.fx_text_all(global_position + Vector3.UP * 2.6, "BILLED IN A PARTNER", "#ffd23f")
		"tank":
			_move_to(tpos, speed, float(def.melee_range_m) * 0.8)
			if dist <= float(def.melee_range_m):
				_try_melee(target)
			if special_cd <= 0.0 and dist < 14.0 and team == "enemy":
				special_cd = float(def.barrier_cooldown_s)
				_deploy_barrier(tpos)


func _pick_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	if team == "player":
		for e in arena.enemies():
			if e != self and e.team == "enemy" and e.is_alive():
				var d := global_position.distance_to(e.global_position)
				if d < best_d:
					best_d = d
					best = e
		return best
	for p in arena.players():
		if not p.downed:
			var d := global_position.distance_to(p.global_position)
			if d < best_d:
				best_d = d
				best = p
	for e in arena.enemies():
		if e.team == "player" and e.is_alive():
			var d := global_position.distance_to(e.global_position) + 2.0
			if d < best_d:
				best_d = d
				best = e
	return best


func _move_to(pos: Vector3, speed: float, stop_dist: float) -> void:
	var to := pos - global_position
	to.y = 0.0
	if to.length() > stop_dist and speed > 0.0:
		var d := to.normalized()
		velocity.x = d.x * speed
		velocity.z = d.z * speed
		_face(pos)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()


func _face(pos: Vector3) -> void:
	var to := pos - global_position
	to.y = 0.0
	if to.length() > 0.05:
		rotation.y = atan2(-to.x, -to.z)


func _try_melee(target: Node3D) -> void:
	if attack_cd > 0.0:
		return
	attack_cd = float(def.melee_cooldown_s) * (0.75 if regressed else 1.0)
	var dmg := float(def.melee_damage) * (1.3 if regressed else 1.0)
	if target is Player:
		arena.damage_player(target, dmg, float(def.get("melee_morale", 0.0)), def.name_en)
	elif target is Enemy:
		target.server_damage(dmg * 2.0, null)
	arena.fx_burst_all(target.global_position + Vector3.UP, 0.4, "#ffffff")


func _shoot(target: Node3D) -> void:
	if team == "player":
		# Convinced enemies argue on the player's side: instant "hit" with a tracer.
		if target is Enemy:
			target.server_damage(float(def.get("ranged_damage", 5)) * 3.0, null)
			arena.fx_tracer_all(center(), target.center(), "#7dff6b")
		return
	var from := center() + Vector3.UP * 0.4
	var aim: Vector3 = (target.global_position + Vector3.UP * 1.1) - from
	var spd := float(def.get("ranged_speed", 14))
	arena.projectiles.spawn(str(def.ranged_kind), from, aim.normalized() * spd, "enemy", {
		"damage": float(def.ranged_damage) * (1.3 if regressed else 1.0),
		"morale": float(def.get("ranged_morale", 0.0)),
		"source": def.name_en,
	})


func _deploy_barrier(toward: Vector3) -> void:
	var dir := toward - global_position
	dir.y = 0.0
	dir = dir.normalized()
	var pos := global_position + dir * 2.5 + Vector3.UP * 1.5
	var id := arena.spawn_wall(pos, Vector3(float(def.barrier_width_m), 3.0, 0.4), atan2(dir.x, dir.z), "#f2d14b", "APPROVAL PENDING", float(def.barrier_duration_s))
	barrier_ids.append(id)


func _ragdoll_tick(delta: float) -> void:
	velocity.x = ragdoll_vel.x
	velocity.z = ragdoll_vel.z
	ragdoll_vel *= pow(0.25, delta)
	move_and_slide()
	for e in arena.enemies():
		if e == self or not e.is_alive() or ragdoll_hit.has(e.name):
			continue
		if e.global_position.distance_to(global_position) < 1.6:
			ragdoll_hit[e.name] = true
			var killed: bool = e.server_damage(float(ragdoll_hit.damage), ragdoll_source, {"weapon": "NIB"})
			arena.fx_burst_all(e.center(), 0.7, "#7cf7ff")
			if not killed:
				e.server_ragdoll(ragdoll_vel * 0.6, 0.6, float(ragdoll_hit.damage) * 0.5, ragdoll_source)


func _on_status_end(k: String) -> void:
	match k:
		"ally":
			team = "enemy"
			arena.fx_text_all(global_position + Vector3.UP * 2.4, "...wait, what did I agree to?", "#ffffff", 28)
		"ragdoll":
			server_damage(25.0, ragdoll_source, {"weapon": "NIB"})
		"stunned":
			dialogue_owner = 0
