class_name Combat
extends Node
## Host-side weapon resolution. Every number goes through the shooter's StatResolver, so
## modded clients can't inflate damage (GDD 7.8).

var arena: Arena
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()


## Returns true if the shot hit something damageable (feeds the "missed shots" roast context).
func fire(p: Player, w: Dictionary, origin: Vector3, dir: Vector3, charge: float) -> bool:
	match str(w.kind):
		"hitscan_spread":
			return _fire_shotgun(p, w, origin, dir)
		"charge_bolt":
			return _fire_bolt(p, w, origin, dir, charge)
		"projectile_feature":
			_fire_scope_creep(p, w, origin, dir)
			return true
	return false


func _fire_shotgun(p: Player, w: Dictionary, origin: Vector3, dir: Vector3) -> bool:
	var ctx := p.weapon_ctx(w)
	var spread := deg_to_rad(p.resolver.get_stat("spread", float(w.spread_deg), ctx))
	var ends: Array = []
	var hit_any := false
	for i in int(w.pellets):
		var d := _spread_dir(dir, spread)
		var h := hitscan(origin, d, float(w.range_m))
		ends.append(h.position)
		if h.target:
			hit_any = true
			apply_hit(p, w, h.target, h.weakpoint, float(w.damage), h.position)
	arena.fx_tracers_all(origin + dir * 0.6, ends, str(w.color))
	return hit_any


func _fire_bolt(p: Player, w: Dictionary, origin: Vector3, dir: Vector3, charge: float) -> bool:
	var ctx := p.weapon_ctx(w)
	var need := p.resolver.get_stat("charge_time", float(w.charge_time_s), ctx)
	var charged := charge >= need * 0.95
	var h := hitscan(origin, dir, float(w.range_m))
	arena.fx_tracers_all(origin + dir * 0.6, [h.position], "#ffffff" if charged else str(w.color))
	if h.target == null:
		return false
	var base := float(w.damage)
	if charged and h.target is Boss:
		base *= float(w.charged_damage_mult_boss)
	var killed := apply_hit(p, w, h.target, h.weakpoint, base, h.position)
	if charged and not killed and h.target is Enemy and h.target.is_alive() and h.target.team == "enemy":
		# "Narrative Integrity": freeze the target in a dialogue wheel; the shooter picks 1/2/3.
		var stun := float(w.stun_s)
		h.target.server_stun(stun, p.peer_id)
		p.client_dialogue_open.rpc_id(p.peer_id, str(h.target.name), stun)
		arena.fx_text_all(h.target.global_position + Vector3.UP * 2.6, "DIALOGUE CHOICE", "#7cf7ff", 40)
	return true


func _fire_scope_creep(p: Player, w: Dictionary, origin: Vector3, dir: Vector3) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - p.scl_last_shot > float(w.bloat_reset_s):
		p.scl_bloat = 0
	p.scl_last_shot = now
	var bloat := 1.0 + float(w.bloat_per_shot) * p.scl_bloat
	p.scl_bloat += 1
	arena.projectiles.spawn("scope_creep", origin + dir * 0.9, dir * float(w.projectile_speed), "player", {
		"shooter": p.peer_id, "weapon": w.id, "scale": bloat, "dir": dir,
	})
	arena.boss_context("player_used_scope_creep")


## Physics raycast against level, enemies and weak points.
## Returns {position, target (Enemy/Boss or null), weakpoint}.
func hitscan(origin: Vector3, dir: Vector3, range_m: float) -> Dictionary:
	var space := arena.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m, Layers.SHOT_MASK)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var r := space.intersect_ray(q)
	if r.is_empty():
		return {"position": origin + dir * range_m, "target": null, "weakpoint": false}
	var col: Object = r.collider
	var target: Node = col.get_meta("hit_owner") if col.has_meta("hit_owner") else null
	if target != null and not is_instance_valid(target):
		target = null
	return {"position": r.position, "target": target, "weakpoint": col.has_meta("weakpoint")}


## Full damage pipeline for one hit. Returns true on kill.
func apply_hit(p: Player, w: Dictionary, target: Node, weakpoint: bool, base: float, pos: Vector3, extra := {}) -> bool:
	if target == null or not target.is_alive():
		return false
	var ctx := p.weapon_ctx(w, target.get_target_tags())
	var crit: bool = p.resolver.roll_crit(float(w.get("crit_chance", 0.05)), ctx, rng) and not extra.get("no_crit", false)
	var res := p.resolver.compute_damage(base, ctx, {
		"crit": crit, "weakpoint": weakpoint, "window_mult": target.window_mult(),
		"resist": target.current_resist(), "extra_more": p.extra_more(),
	})
	var killed: bool = target.server_damage(res.amount, p, {"weakpoint": weakpoint, "crit": crit, "weapon": w.id})
	p.client_hit.rpc_id(p.peer_id, pos, res.amount, crit, weakpoint, StatResolver.format_breakdown(res.breakdown, res.amount))
	CombatBus.emit_event("on_hit", p.peer_id, {"amount": res.amount, "weapon": w.id, "weakpoint": weakpoint})
	run_triggers(p, "on_hit", {"target": target})
	if crit:
		CombatBus.emit_event("on_crit", p.peer_id, {"weapon": w.id})
		run_triggers(p, "on_crit", {"target": target})
	return killed


## Area damage from a player's weapon (explosions, confetti). Returns kills.
func aoe(p: Player, w: Dictionary, center: Vector3, radius: float, base: float, exclude: Node = null) -> int:
	var kills := 0
	var targets: Array = arena.enemies() + arena.bosses()
	for t in targets:
		if t == exclude or not t.is_alive():
			continue
		if t is Enemy and t.team != "enemy":
			continue
		if t.center().distance_to(center) <= radius + 0.6:
			if p:
				if apply_hit(p, w, t, false, base, t.center(), {"no_crit": true}):
					kills += 1
			elif t.server_damage(base, null):
				kills += 1
	return kills


## Shotgun regression roll: "Each kill has 10% chance to introduce a regression."
func maybe_regress(killed_at: Vector3, w: Dictionary) -> void:
	if rng.randf() >= float(w.get("regression_chance", 0.0)):
		return
	var near: Array = []
	for e in arena.enemies():
		if e.is_alive() and e.team == "enemy" and e.global_position.distance_to(killed_at) <= float(w.regression_radius_m):
			near.append(e)
	if near.is_empty():
		return
	var e: Enemy = near.pick_random()
	e.server_regress(float(w.regression_duration_s))
	arena.fx_text_all(e.global_position + Vector3.UP * 2.6, "REGRESSION INTRODUCED", "#c38bff", 44)


func dialogue_choice(p: Player, enemy_name: String, choice: String) -> void:
	var e: Enemy = arena.enemy_by_name(enemy_name)
	if e == null or not e.is_alive() or e.dialogue_owner != p.peer_id or not e.status.has("stunned"):
		return
	var w: Dictionary = Data.weapons.NIB
	match choice:
		"agree":
			arena.fx_text_all(e.global_position + Vector3.UP * 2.4, "\"You know what? Fair.\"", "#ffd23f", 40)
			var pos := e.center()
			apply_hit(p, w, e, false, e.hp + 1.0, pos, {"no_crit": true})
			aoe(p, w, pos, float(w.agree_aoe_radius_m), float(w.agree_aoe_damage), e)
			arena.fx_confetti_all(pos, 120)
		"disagree":
			var dir := e.global_position - p.global_position
			dir.y = 0.0
			e.server_ragdoll(dir.normalized() * float(w.disagree_speed), float(w.disagree_duration_s), float(w.disagree_impact_damage), p)
			arena.fx_text_all(e.global_position + Vector3.UP * 2.4, "\"Agree to disagree!\"", "#ff6b6b", 40)
		"lie":
			e.server_turn_ally(float(w.lie_duration_s))
			arena.fx_text_all(e.global_position + Vector3.UP * 2.4, "[Lie] \"Great synergy, team!\"", "#7dff6b", 40)


## GOLD MASTER: 8 s invulnerable, infinite ammo, +100% damage, enemies flinch in a ripple.
func gold_master(p: Player) -> void:
	CombatBus.emit_event("on_ability_used", p.peer_id, {"ability": "GOLD_MASTER"})
	for e in arena.enemies():
		if e.global_position.distance_to(p.global_position) < 20.0:
			e.status["flinch"] = 0.8
	arena.fx_text_all(p.global_position + Vector3.UP * 2.6, "GOLD MASTER — IT SHIPPED", "#ffd23f", 72)
	arena.fx_burst_all(p.global_position + Vector3.UP, 8.0, "#ffd23f")


## Tree "trigger" effects (GDD 7.5 / 7.7). Supported actions: heal, add_ult_charge,
## refund_ammo, aoe_damage. Unknown actions are ignored so data can run ahead of code.
func run_triggers(p: Player, event: String, payload: Dictionary) -> void:
	for t in p.resolver.triggers:
		if str(t.get("event", "")) != event:
			continue
		if rng.randf() > float(t.get("chance", 1.0)):
			continue
		var cd_key := "_trig_cd_%s" % t.source
		var now := Time.get_ticks_msec() / 1000.0
		if p.has_meta(cd_key) and now < float(p.get_meta(cd_key)):
			continue
		if t.has("cooldown"):
			p.set_meta(cd_key, now + float(t.cooldown))
		var a: Dictionary = t.get("action", {})
		match str(a.get("type", "")):
			"heal":
				p.server_heal(float(a.get("value", 0.0)) * p.max_hp)
			"add_ult_charge":
				p.server_add_ult(float(a.get("value", 0.0)))
			"refund_ammo":
				var wid := p.current_weapon_id()
				var mag := int(Data.weapons[wid].magazine)
				p.ammo[wid] = min(mag, int(p.ammo[wid]) + int(ceil(mag * float(a.get("value", 0.1)))))
			"aoe_damage":
				var tgt: Node = payload.get("target")
				if tgt and is_instance_valid(tgt):
					aoe(null, {}, tgt.center(), float(a.get("radius_m", 3.0)), float(a.get("value", 20.0)))


static func _spread_dir(dir: Vector3, spread_rad: float) -> Vector3:
	var basis := Basis.looking_at(dir, Vector3.UP if abs(dir.y) < 0.99 else Vector3.RIGHT)
	var a := randf() * TAU
	var r := sqrt(randf()) * tan(spread_rad)
	return (basis * Vector3(cos(a) * r, sin(a) * r, -1.0)).normalized()
