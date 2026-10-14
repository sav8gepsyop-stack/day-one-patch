class_name Player
extends CharacterBody3D
## First-person co-op player.
##
## Authority split (GDD 7.8 / 10.3): the owning peer simulates its own movement and aim
## (replicated by a MultiplayerSynchronizer), while the host owns everything that matters
## for fairness: HP, Morale, ammo, damage, tree purchases and currencies. Clients send
## requests (srv_*) and render the state the host broadcasts (_sync_state).

const EYE_HEIGHT := 1.6
const WALK_SPEED := 7.5
const SPRINT_SPEED := 11.0
const JUMP_VELOCITY := 6.5
const GRAVITY := 20.0
const BASE_HP := 100.0
const BLEED_OUT_S := 15.0
const SOLO_BLEED_OUT_S := 5.0
const REVIVE_TIME_S := 3.0
const REVIVE_RANGE_M := 2.6
const INTERACT_RANGE_M := 2.4
const ULT_DURATION_S := 8.0
const ULT_KILL_CHARGE := 4.0
const LOW_HP_FRAC := 0.25
const MISSED_SHOTS_CONTEXT := 3

static var local: Player = null

var peer_id := 1
var display_name := "Crusader"
var arena: Arena

# Replicated from the owner (MultiplayerSynchronizer).
var sync_pos := Vector3.ZERO
var sync_yaw := 0.0
var sync_pitch := 0.0
var weapon_idx := 0

# Host-authoritative, mirrored to everyone through _sync_state.
var hp := BASE_HP
var max_hp := BASE_HP
var morale := 0.0
var downed := false
var bleed_left := 0.0
var revive_progress := 0.0
var ult_charge := 0.0
var ult_left := 0.0
var crunch_left := 0.0
var ammo: Dictionary = {}
var reload_left := 0.0
var reload_weapon := ""
var milestone := 1
var wallet: Dictionary = {}
var tags_view: Array = []

# Host-only.
var toolset := PlayerToolsetState.new()
var resolver := StatResolver.new()
var assist := "off"
var docs_read: Array = []
var interact_held := false
var scl_bloat := 0
var scl_last_shot := -100.0
var missed_streak := 0
var damage_dealt_boss := 0.0
var coffee_times: Array = []
var jitter_left := 0.0
var _fire_ready_at: Dictionary = {}
var _last_charged_shot := -100.0
var _low_hp_flag := false
var _dirty := true
var _sync_accum := 0.0

# Owner-only.
var head: Node3D
var camera: Camera3D
var viewmodel: Node3D
var body_mesh: Node3D
var name_label: Label3D
var spotlight: SpotLight3D
var local_resolver := StatResolver.new()
var toolset_view: Dictionary = {}
var statuses: Dictionary = {}       # rooted / slowed / frozen / jitters -> seconds left
var dialogue_pending: Dictionary = {}  # {enemy, until}
var input_enabled := true
var _charge_t := 0.0
var _charging := false
var _local_ready_at := 0.0
var _hit_marker_t := 0.0


static func create(peer: int, display: String, pos: Vector3) -> Player:
	var p := Player.new()
	p.name = "P_%d" % peer
	p.peer_id = peer
	p.display_name = display
	p.position = pos
	p.sync_pos = pos
	p._build()
	p.set_multiplayer_authority(peer)
	return p


func _build() -> void:
	collision_layer = Layers.PLAYER
	collision_mask = Layers.WORLD
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	shape.shape = cap
	shape.position = Vector3(0, 0.9, 0)
	add_child(shape)

	body_mesh = Node3D.new()
	body_mesh.name = "Body"
	add_child(body_mesh)
	var hoodie := Color.from_hsv(float(peer_id % 7) / 7.0, 0.55, 0.85)
	body_mesh.add_child(Fx.capsule(0.4, 1.5, hoodie, Vector3(0, 0.75, 0)))
	body_mesh.add_child(Fx.sphere(0.25, Color("#e8c39e"), Vector3(0, 1.65, 0)))
	body_mesh.add_child(Fx.box(Vector3(0.36, 0.08, 0.1), Color("#111111"), Vector3(0, 1.68, -0.2)))
	body_mesh.add_child(Fx.box(Vector3(0.08, 0.5, 0.02), Color("#2f6bff"), Vector3(0, 1.2, -0.38)))  # lanyard

	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(head)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 90.0
	camera.near = 0.05
	head.add_child(camera)
	viewmodel = Node3D.new()
	viewmodel.position = Vector3(0.28, -0.25, -0.5)
	camera.add_child(viewmodel)

	name_label = Fx.label(display_name, Color.WHITE, Vector3(0, 2.25, 0), 36)
	name_label.no_depth_test = false
	add_child(name_label)

	spotlight = SpotLight3D.new()
	spotlight.position = Vector3(0, 6.0, 0)
	spotlight.rotation_degrees = Vector3(-90, 0, 0)
	spotlight.spot_range = 9.0
	spotlight.spot_angle = 22.0
	spotlight.light_energy = 6.0
	spotlight.light_color = Color("#fff3a0")
	spotlight.visible = false
	add_child(spotlight)

	Fx.add_sync(self, ["sync_pos", "sync_yaw", "sync_pitch", "weapon_idx"], ["weapon_idx"])


func _ready() -> void:
	arena = Arena.current
	add_to_group("players")
	for id in Data.loadout():
		ammo[id] = int(Data.weapons[id].magazine)
	if is_multiplayer_authority():
		local = self
		camera.make_current()
		body_mesh.visible = false
		name_label.visible = false
		_rebuild_viewmodel()
		_srv_request_sync.rpc_id(1)
	else:
		camera.current = false


func _exit_tree() -> void:
	if local == self:
		local = null


func is_alive() -> bool:
	return not downed


func current_weapon_id() -> String:
	var lo := Data.loadout()
	return lo[clampi(weapon_idx, 0, lo.size() - 1)]


func eye_position() -> Vector3:
	return global_position + Vector3(0, EYE_HEIGHT, 0)


func morale_band() -> String:
	return MoraleRules.band(morale, crunch_left > 0.0)


func has_tag(tag: String) -> bool:
	return tags_view.has(tag)


func weapon_ctx(w: Dictionary, target_tags: Array = []) -> Dictionary:
	return {
		"weapon_tags": w.get("tags", []),
		"target_tags": target_tags,
		"player_state": {"morale": morale, "hp_frac": hp / max(max_hp, 1.0), "in_damage_window": arena != null and arena.boss_window_open()},
		"nearest_ally_m": _nearest_ally_m(),
	}


## Temporary "more" multipliers: Crunch State and GOLD MASTER.
func extra_more() -> Array:
	var out: Array = []
	if crunch_left > 0.0:
		out.append(MoraleRules.CRUNCH_DAMAGE_MORE)
	if ult_left > 0.0:
		out.append(1.0)
	return out


func _nearest_ally_m() -> float:
	var best := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p != self:
			best = min(best, global_position.distance_to(p.global_position))
	return best


# =========================================================================================
# Frame loop
# =========================================================================================

func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		_owner_physics(delta)
	else:
		global_position = global_position.lerp(sync_pos, clampf(delta * 15.0, 0.0, 1.0))
		rotation.y = lerp_angle(rotation.y, sync_yaw, clampf(delta * 15.0, 0.0, 1.0))
		head.rotation.x = sync_pitch
	body_mesh.rotation.x = lerpf(body_mesh.rotation.x, -1.3 if downed else 0.0, clampf(delta * 6.0, 0.0, 1.0))
	if multiplayer.is_server():
		_server_tick(delta)


func _owner_physics(delta: float) -> void:
	for k in statuses.keys():
		statuses[k] -= delta
		if statuses[k] <= 0.0:
			statuses.erase(k)
	_hit_marker_t = max(0.0, _hit_marker_t - delta)
	var can_act := input_enabled and not downed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or (input_enabled and Game.is_headless())
	var dir := Vector3.ZERO
	if can_act and not downed and not statuses.has("rooted"):
		var iv := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		dir = (transform.basis * Vector3(iv.x, 0, iv.y)).normalized()
	var speed := SPRINT_SPEED if Input.is_action_pressed("sprint") else WALK_SPEED
	speed *= local_resolver.get_stat("move_speed", 1.0) * MoraleRules.speed_mult(morale_band())
	if statuses.has("slowed"):
		speed *= 0.5
	if statuses.has("frozen"):
		speed *= 0.6
	velocity.x = move_toward(velocity.x, dir.x * speed, speed * (12.0 if is_on_floor() else 3.0) * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, speed * (12.0 if is_on_floor() else 3.0) * delta)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif can_act and not downed and Input.is_action_just_pressed("jump") and not statuses.has("rooted"):
		velocity.y = JUMP_VELOCITY
	move_and_slide()
	if global_position.y < -20.0:
		global_position = arena.player_spawn_point(peer_id) if arena else Vector3(0, 1, 0)
		velocity = Vector3.ZERO
	head.position.y = 0.5 if downed else EYE_HEIGHT
	if statuses.has("jitters"):
		camera.rotation.x = randf_range(-0.01, 0.01)
		camera.rotation.y = randf_range(-0.01, 0.01)
	else:
		camera.rotation = Vector3.ZERO
	sync_pos = global_position
	sync_yaw = rotation.y
	sync_pitch = head.rotation.x
	if can_act:
		_owner_actions(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := float(Game.settings.mouse_sensitivity)
		rotate_y(-event.relative.x * sens)
		head.rotation.x = clampf(head.rotation.x - event.relative.y * sens, -1.45, 1.45)


func _owner_actions(delta: float) -> void:
	var roast_ui := RoastUi.instance
	var roast_live := roast_ui != null and roast_ui.is_accepting_input()
	for i in 4:
		if Input.is_action_just_pressed("slot_%d" % (i + 1)):
			if roast_live:
				roast_ui.select_counter(i)
			elif not dialogue_pending.is_empty() and i < 3:
				_srv_dialogue_choice.rpc_id(1, str(dialogue_pending.enemy), ["agree", "disagree", "lie"][i])
				dialogue_pending.clear()
			elif i < Data.loadout().size():
				_switch_weapon(i)
	if Input.is_action_just_pressed("deflect") and roast_live:
		roast_ui.press_deflect()
	if Input.is_action_just_pressed("next_weapon"):
		_switch_weapon((weapon_idx + 1) % Data.loadout().size())
	if Input.is_action_just_pressed("prev_weapon"):
		_switch_weapon((weapon_idx + Data.loadout().size() - 1) % Data.loadout().size())
	if Input.is_action_just_pressed("reload"):
		_srv_reload.rpc_id(1, current_weapon_id())
	if Input.is_action_just_pressed("interact"):
		_srv_interact.rpc_id(1, true)
	if Input.is_action_just_released("interact"):
		_srv_interact.rpc_id(1, false)
	if Input.is_action_just_pressed("ultimate"):
		_srv_ultimate.rpc_id(1)
	if Input.is_action_just_pressed("debug_credits") and OS.is_debug_build():
		_srv_debug_credits.rpc_id(1)
	if not dialogue_pending.is_empty() and Time.get_ticks_msec() / 1000.0 > float(dialogue_pending.until):
		dialogue_pending.clear()
	_owner_fire(delta)


func _owner_fire(delta: float) -> void:
	var wid := current_weapon_id()
	var w: Dictionary = Data.weapons[wid]
	var now := Time.get_ticks_msec() / 1000.0
	if downed:
		_charging = false
		return
	if w.kind == "charge_bolt":
		if Input.is_action_pressed("fire"):
			if not _charging and now >= _local_ready_at:
				_charging = true
				_charge_t = 0.0
			if _charging:
				_charge_t += delta
		elif _charging:
			_charging = false
			fire_weapon(wid, _charge_t)
		return
	if Input.is_action_pressed("fire") and now >= _local_ready_at:
		fire_weapon(wid, 0.0)


## Owner-side fire request. Public so the autotest driver can use the real network path.
func fire_weapon(wid: String, charge: float, aim_dir := Vector3.ZERO) -> void:
	var w: Dictionary = Data.weapons[wid]
	var now := Time.get_ticks_msec() / 1000.0
	if int(ammo.get(wid, 0)) <= 0 and ult_left <= 0.0:
		if reload_left <= 0.0:
			_srv_reload.rpc_id(1, wid)
		_local_ready_at = now + 0.3
		return
	var rate := local_resolver.get_stat("fire_rate", float(w.fire_rate), {"weapon_tags": w.tags})
	if statuses.has("jitters"):
		rate *= 1.2
	_local_ready_at = now + 1.0 / max(rate, 0.05)
	var dir := aim_dir if aim_dir != Vector3.ZERO else -camera.global_transform.basis.z
	_kick_viewmodel()
	_srv_fire.rpc_id(1, wid, camera.global_position, dir.normalized(), charge)


func charge_fraction() -> float:
	if not _charging:
		return 0.0
	var w: Dictionary = Data.weapons[current_weapon_id()]
	var need := local_resolver.get_stat("charge_time", float(w.get("charge_time_s", 1.0)), {"weapon_tags": w.tags})
	return clampf(_charge_t / max(need, 0.05), 0.0, 1.0)


func hit_marker_alpha() -> float:
	return _hit_marker_t / 0.15


func _switch_weapon(i: int) -> void:
	if i == weapon_idx:
		return
	weapon_idx = i
	_charging = false
	_rebuild_viewmodel()


func _rebuild_viewmodel() -> void:
	for c in viewmodel.get_children():
		c.queue_free()
	var w: Dictionary = Data.weapons[current_weapon_id()]
	var col := JsonUtil.color(str(w.get("color", "")), Color.GRAY)
	match w.id:
		"HFS":
			viewmodel.add_child(Fx.box(Vector3(0.12, 0.14, 0.7), Color("#3a3a3a")))
			viewmodel.add_child(Fx.box(Vector3(0.14, 0.1, 0.25), col, Vector3(0, -0.02, -0.15)))
		"NIB":
			viewmodel.add_child(Fx.box(Vector3(0.1, 0.12, 0.5), Color("#dddddd")))
			viewmodel.add_child(Fx.sphere(0.08, col, Vector3(0, 0.0, -0.3), true))
		"SCL":
			viewmodel.add_child(Fx.cylinder(0.11, 0.8, col, Vector3.ZERO))
			viewmodel.get_child(-1).rotation_degrees = Vector3(90, 0, 0)
			viewmodel.add_child(Fx.box(Vector3(0.3, 0.2, 0.05), Color("#ffd23f"), Vector3(0, 0.15, -0.1)))


func _kick_viewmodel() -> void:
	var tw := viewmodel.create_tween()
	tw.tween_property(viewmodel, "position:z", -0.42, 0.04)
	tw.tween_property(viewmodel, "position:z", -0.5, 0.12)


# =========================================================================================
# Host: requests from the owning client
# =========================================================================================

func _from_owner() -> bool:
	var s := multiplayer.get_remote_sender_id()
	return multiplayer.is_server() and (s == peer_id or (s == 0 and peer_id == multiplayer.get_unique_id()))


func _from_host() -> bool:
	var s := multiplayer.get_remote_sender_id()
	return s == 1 or s == 0


@rpc("any_peer", "call_local", "reliable")
func _srv_request_sync() -> void:
	if not _from_owner():
		return
	_send_toolset()
	_dirty = true
	if arena:
		arena.send_flow_to(peer_id)


@rpc("any_peer", "call_local", "reliable")
func _srv_fire(wid: String, origin: Vector3, dir: Vector3, charge: float) -> void:
	if not _from_owner() or downed or not Data.weapons.has(wid) or not Data.loadout().has(wid):
		return
	var w: Dictionary = Data.weapons[wid]
	var now := Time.get_ticks_msec() / 1000.0
	if reload_left > 0.0 and reload_weapon == wid:
		return
	if now < float(_fire_ready_at.get(wid, 0.0)) - 0.06:
		return  # faster than the resolver allows (tolerate jitter)
	var ctx := weapon_ctx(w)
	var rate := resolver.get_stat("fire_rate", float(w.fire_rate), ctx) * (1.2 if jitter_left > 0.0 else 1.0)
	_fire_ready_at[wid] = now + 1.0 / max(rate, 0.05)
	if ult_left <= 0.0:
		if int(ammo.get(wid, 0)) <= 0:
			server_start_reload(wid)
			return
		ammo[wid] = int(ammo[wid]) - 1
	if origin.distance_to(eye_position()) > 3.0:
		origin = eye_position()  # don't trust far-off origins
	if w.kind == "charge_bolt":
		var need := resolver.get_stat("charge_time", float(w.charge_time_s), ctx)
		var since := now - _last_charged_shot
		charge = min(charge, since)
		if charge >= need * 0.95:
			_last_charged_shot = now
	CombatBus.emit_event("on_shot_fired", peer_id, {"weapon": wid})
	var hit_any: bool = arena.combat.fire(self, w, origin, dir.normalized(), charge)
	if w.kind != "projectile_feature":
		missed_streak = 0 if hit_any else missed_streak + 1
		if missed_streak >= MISSED_SHOTS_CONTEXT:
			arena.boss_context("player_missed_shots")
			missed_streak = 0
	if int(ammo[wid]) <= 0 and ult_left <= 0.0:
		server_start_reload(wid)
	_dirty = true


@rpc("any_peer", "call_local", "reliable")
func _srv_reload(wid: String) -> void:
	if _from_owner() and not downed and Data.weapons.has(wid):
		server_start_reload(wid)


@rpc("any_peer", "call_local", "reliable")
func _srv_interact(held: bool) -> void:
	if not _from_owner():
		return
	interact_held = held
	if held and not downed:
		arena.server_interact(self)


@rpc("any_peer", "call_local", "reliable")
func _srv_ultimate() -> void:
	if not _from_owner() or downed:
		return
	if not resolver.has_tag("ult_available"):
		client_toast.rpc_id(peer_id, "GOLD MASTER locked: buy Manual Build (Build Pipeline T0)", "#ffb347")
		return
	if ult_charge < 100.0 or ult_left > 0.0:
		return
	ult_charge = 0.0
	ult_left = ULT_DURATION_S
	arena.combat.gold_master(self)
	_dirty = true


@rpc("any_peer", "call_local", "reliable")
func srv_purchase(node_id: String) -> void:
	if not _from_owner():
		return
	var reason := toolset.purchase(Data.tree, node_id, milestone)
	if reason == "":
		_on_toolset_changed()
		var n := Data.tree.get_node_def(node_id)
		client_toast.rpc_id(peer_id, "Installed: %s" % n.name_en, "#7dff6b")
	else:
		client_toast.rpc_id(peer_id, "Can't install: %s" % reason.replace("_", " "), "#ff6b6b")


@rpc("any_peer", "call_local", "reliable")
func srv_respec() -> void:
	if not _from_owner():
		return
	var fee := toolset.respec(Data.tree)
	_on_toolset_changed()
	client_toast.rpc_id(peer_id, "Refactored (fee %d SC)" % fee, "#7cf7ff")


@rpc("any_peer", "call_local", "reliable")
func _srv_dialogue_choice(enemy_name: String, choice: String) -> void:
	if _from_owner():
		arena.combat.dialogue_choice(self, enemy_name, choice)


@rpc("any_peer", "call_local", "reliable")
func _srv_debug_credits() -> void:
	if _from_owner() and OS.is_debug_build():
		toolset.add_currency("studio_credits", int(Data.slice.get("debug_credit_grant", 1000)))
		_send_toolset()
		_dirty = true


# =========================================================================================
# Host: simulation
# =========================================================================================

## Called by the arena right after spawning, with the profile the client sent.
func server_setup(profile: Dictionary) -> void:
	toolset = PlayerToolsetState.from_dict(profile.get("toolset", {}))
	var dropped := toolset.sanitize(Data.tree)
	if not dropped.is_empty():
		push_warning("Dropped invalid tree nodes for %s: %s" % [display_name, dropped])
	assist = str(profile.get("assist", "off"))
	milestone = max(int(profile.get("milestone", 0)), int(Data.slice.get("starting_milestone", 0)))
	docs_read = profile.get("docs_read", []).duplicate()
	resolver.rebuild(Data.tree, toolset.unlocked)
	max_hp = resolver.get_stat("max_hp", BASE_HP)
	hp = max_hp


func _on_toolset_changed() -> void:
	var frac := hp / maxf(max_hp, 1.0)
	resolver.rebuild(Data.tree, toolset.unlocked)
	max_hp = resolver.get_stat("max_hp", BASE_HP)
	hp = max_hp * frac
	_send_toolset()
	_dirty = true


func _send_toolset() -> void:
	client_toolset.rpc_id(peer_id, toolset.to_dict(), milestone)


func server_start_reload(wid: String) -> void:
	if reload_left > 0.0 or int(ammo.get(wid, 0)) >= int(Data.weapons[wid].magazine):
		return
	var w: Dictionary = Data.weapons[wid]
	var speed := resolver.get_stat("reload_speed", 1.0, weapon_ctx(w))
	reload_left = float(w.reload_s) / max(speed, 0.1) * MoraleRules.reload_time_mult(morale_band())
	reload_weapon = wid
	CombatBus.emit_event("on_reload_start", peer_id, {"weapon": wid})
	_dirty = true


func server_take_damage(amount: float, morale_amount: float, source := "") -> void:
	if downed or ult_left > 0.0:
		return
	if crunch_left > 0.0:
		amount *= MoraleRules.CRUNCH_TAKEN_MULT
	hp -= amount
	if morale_amount > 0.0:
		server_add_morale(morale_amount)
	CombatBus.emit_event("on_damage_taken", peer_id, {"amount": amount, "source": source})
	if hp <= 0.0:
		_server_down()
	elif hp / max_hp < LOW_HP_FRAC and not _low_hp_flag:
		_low_hp_flag = true
		arena.boss_context("player_low_hp")
	_dirty = true


## Positive = Morale damage (scaled by morale_damage_taken), negative = relief.
func server_add_morale(amount: float) -> void:
	if amount > 0.0:
		amount *= resolver.get_stat("morale_damage_taken", 1.0)
	if crunch_left > 0.0 and amount > 0.0:
		return
	var before := morale_band()
	morale = clampf(morale + amount, 0.0, MoraleRules.MAX)
	if morale >= MoraleRules.MAX and crunch_left <= 0.0:
		crunch_left = MoraleRules.CRUNCH_DURATION_S
		arena.fx_text_all(global_position + Vector3.UP * 2.4, "CRUNCH STATE", "#ff3b3b")
	if morale_band() != before:
		CombatBus.emit_event("on_morale_threshold", peer_id, {"band": morale_band()})
	_dirty = true


func server_heal(amount: float) -> void:
	if downed:
		return
	hp = min(max_hp, hp + amount)
	if hp / max_hp >= LOW_HP_FRAC:
		_low_hp_flag = false
	_dirty = true


func server_add_ult(amount: float) -> void:
	if ult_left > 0.0:
		return
	ult_charge = min(100.0, ult_charge + amount * resolver.get_stat("ult_charge_rate", 1.0))
	_dirty = true


func server_set_status(kind: String, seconds: float) -> void:
	client_status.rpc_id(peer_id, kind, seconds)


func _server_down() -> void:
	hp = 0.0
	downed = true
	revive_progress = 0.0
	bleed_left = SOLO_BLEED_OUT_S if arena.players().size() <= 1 else BLEED_OUT_S
	CombatBus.emit_event("on_ally_downed", peer_id)
	arena.fx_text_all(global_position + Vector3.UP * 1.5, "%s needs a code review!" % display_name, "#ff6b6b")
	_dirty = true


func _server_revive(frac: float, respawn: bool) -> void:
	downed = false
	hp = max_hp * frac
	_low_hp_flag = false
	if respawn:
		morale = min(morale, MoraleRules.CRUNCH_RESET_TO)
		client_teleport.rpc_id(peer_id, arena.player_spawn_point(peer_id))
		arena.boss_context("player_respawned")
	CombatBus.emit_event("on_revive", peer_id, {"respawn": respawn})
	_dirty = true


func _server_tick(delta: float) -> void:
	if reload_left > 0.0:
		reload_left -= delta
		if reload_left <= 0.0:
			reload_left = 0.0
			ammo[reload_weapon] = int(Data.weapons[reload_weapon].magazine)
			CombatBus.emit_event("on_reload_end", peer_id, {"weapon": reload_weapon})
			_dirty = true
	if crunch_left > 0.0:
		crunch_left -= delta
		if crunch_left <= 0.0:
			crunch_left = 0.0
			morale = MoraleRules.CRUNCH_RESET_TO
			_dirty = true
	if ult_left > 0.0:
		ult_left = max(0.0, ult_left - delta)
		if ult_left == 0.0:
			_dirty = true
	jitter_left = max(0.0, jitter_left - delta)
	if downed:
		_server_downed_tick(delta)
	_sync_accum += delta
	if (_dirty and _sync_accum >= 0.1) or _sync_accum >= 0.5:
		_sync_accum = 0.0
		_dirty = false
		_sync_state.rpc(_state_dict())


func _server_downed_tick(delta: float) -> void:
	var reviver: Player = null
	for p in arena.players():
		if p != self and not p.downed and p.interact_held and p.global_position.distance_to(global_position) <= REVIVE_RANGE_M:
			reviver = p
			break
	if reviver:
		var speed := reviver.resolver.get_stat("revive_speed", 1.0)
		revive_progress += delta * speed / REVIVE_TIME_S
		if revive_progress >= 1.0:
			_server_revive(0.4, false)
			arena.fx_text_all(global_position + Vector3.UP * 2.0, "Approved by %s" % reviver.display_name, "#7dff6b")
			return
	bleed_left -= delta
	if bleed_left <= 0.0:
		_server_revive(1.0, true)
		arena.fx_text_all(global_position + Vector3.UP * 2.0, "Rolled back to last Commit", "#7cf7ff")
	_dirty = true


func _state_dict() -> Dictionary:
	return {
		"hp": hp, "max_hp": max_hp, "morale": morale, "downed": downed, "bleed": bleed_left,
		"revive": revive_progress, "ult": ult_charge, "ult_left": ult_left, "crunch": crunch_left,
		"ammo": ammo, "reload": reload_left, "reload_w": reload_weapon,
		"wallet": toolset.currencies, "tags": resolver.tags.keys(), "milestone": milestone,
	}


# =========================================================================================
# Clients: state from the host
# =========================================================================================

@rpc("any_peer", "call_local", "reliable")
func _sync_state(d: Dictionary) -> void:
	if not _from_host():
		return
	hp = d.hp
	max_hp = d.max_hp
	morale = d.morale
	downed = d.downed
	bleed_left = d.bleed
	revive_progress = d.revive
	ult_charge = d.ult
	ult_left = d.ult_left
	crunch_left = d.crunch
	ammo = d.ammo
	reload_left = d.reload
	reload_weapon = d.reload_w
	wallet = d.wallet
	tags_view = d.tags
	milestone = d.milestone


@rpc("any_peer", "call_local", "reliable")
func client_toolset(state: Dictionary, new_milestone: int) -> void:
	if not _from_host():
		return
	toolset_view = state
	milestone = new_milestone
	local_resolver.rebuild(Data.tree, state.get("unlocked_nodes", []))
	tags_view = local_resolver.tags.keys()
	if is_multiplayer_authority():
		Game.store_toolset(state, new_milestone)


@rpc("any_peer", "call_local", "reliable")
func client_toast(text: String, color_hex: String) -> void:
	if _from_host() and Hud.instance:
		Hud.instance.toast(text, Color(color_hex))


@rpc("any_peer", "call_local", "reliable")
func client_status(kind: String, seconds: float) -> void:
	if _from_host():
		statuses[kind] = max(float(statuses.get(kind, 0.0)), seconds)


@rpc("any_peer", "call_local", "reliable")
func client_teleport(pos: Vector3) -> void:
	if _from_host() and is_multiplayer_authority():
		global_position = pos
		velocity = Vector3.ZERO


@rpc("any_peer", "call_local", "reliable")
func client_dialogue_open(enemy_name: String, seconds: float) -> void:
	if _from_host():
		dialogue_pending = {"enemy": enemy_name, "until": Time.get_ticks_msec() / 1000.0 + seconds}


@rpc("any_peer", "call_local", "unreliable")
func client_hit(pos: Vector3, amount: float, crit: bool, weak: bool, breakdown: String) -> void:
	if not _from_host():
		return
	_hit_marker_t = 0.15
	if Hud.instance:
		Hud.instance.last_breakdown = breakdown
	if has_tag("show_damage_numbers") or (Hud.instance and Hud.instance.debug_overlay):
		var col := Color("#ffd23f") if crit else (Color("#ff5e5e") if weak else Color.WHITE)
		var txt := "%d%s" % [roundi(amount), "!" if crit else ""]
		if arena:
			Fx.float_text(arena.fx_root, pos + Vector3(randf_range(-0.3, 0.3), 0.3, 0), txt, col, 40 if not crit else 56, 0.8, 1.0)


func damage_dealt_boss_add(amount: float) -> void:
	damage_dealt_boss += amount


func set_roast_spotlight(on: bool) -> void:
	spotlight.visible = on
