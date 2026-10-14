class_name StatResolver
extends RefCounted
## Sums every applicable upgrade-tree modifier for a query context (GDD 7.6).
## Weapons, abilities and counters never read tree nodes directly; they ask the resolver.
##
##   value  = (base + sum flat) * (1 + sum increased) * prod(1 + more_i)
##   damage = value * crit * weak point * insult window * (1 - resist), with the "more"
##            product (window included) capped at MORE_CAP to protect boss tuning.

const STATS := [
	"damage", "weakpoint_damage", "crit_chance", "crit_damage", "fire_rate", "reload_speed",
	"charge_time", "spinup_time", "spread", "max_hp", "morale_damage_taken", "self_morale_drain",
	"ult_charge_rate", "ability_cooldown", "throwable_capacity", "counter_window_perfect_ms",
	"counter_window_good_ms", "damage_window_duration", "revive_speed",
	# Slice additions (GDD 7.5 says the registry is extendable):
	"roast_icon_lead_ms", "move_speed",
]
const MORE_CAP := 6.0
const BASE_CRIT_MULT := 1.5
const BASE_WEAKPOINT_MULT := 2.0

var tags: Dictionary = {}        # tag -> true (grant_tag)
var abilities: Dictionary = {}   # ability_id -> rank (grant_ability)
var rules: Dictionary = {}       # rule -> value (override_rule)
var triggers: Array = []         # trigger effects, consumed by the combat event bus
var _static_mods: Array = []     # mods whose result depends only on weapon/target tags (cacheable)
var _dynamic_mods: Array = []    # mods with player_state / coop conditions, evaluated live
var _cache: Dictionary = {}


func rebuild(db: ToolsetTreeDB, unlocked: Array) -> void:
	tags.clear()
	abilities.clear()
	rules.clear()
	triggers.clear()
	_static_mods.clear()
	_dynamic_mods.clear()
	_cache.clear()
	for id in unlocked:
		var n: Dictionary = db.get_node_def(id)
		for e in n.get("effects", []):
			_apply_effect(e, id)


func has_tag(tag: String) -> bool:
	return tags.has(tag)


func _apply_effect(e: Dictionary, source: String) -> void:
	match str(e.get("op", "")):
		"stat_mod":
			var cond: Dictionary = e.get("conditions", {})
			var mod := {
				"stat": str(e.stat), "bucket": str(e.bucket), "value": float(e.value),
				"conditions": cond, "source": source,
			}
			if cond.has("player_state") or cond.has("coop_allies_within_m"):
				_dynamic_mods.append(mod)
			else:
				_static_mods.append(mod)
		"grant_tag":
			tags[str(e.tag)] = true
		"grant_ability":
			abilities[str(e.ability_id)] = int(e.get("rank", 1))
		"override_rule":
			rules[str(e.rule)] = e.value
		"trigger":
			var t: Dictionary = e.duplicate(true)
			t["source"] = source
			triggers.append(t)


## Returns {flat, increased, more} for a stat in a context.
func aggregate(stat: String, ctx: Dictionary = {}) -> Dictionary:
	var key := _cache_key(stat, ctx)
	var agg: Dictionary
	if _cache.has(key):
		agg = _cache[key].duplicate()
	else:
		agg = {"flat": 0.0, "increased": 0.0, "more": 1.0}
		for m in _static_mods:
			if m.stat == stat and conditions_met(m.conditions, ctx):
				_add(agg, m)
		_cache[key] = agg.duplicate()
	for m in _dynamic_mods:
		if m.stat == stat and conditions_met(m.conditions, ctx):
			_add(agg, m)
	return agg


func get_stat(stat: String, base: float, ctx: Dictionary = {}) -> float:
	var a := aggregate(stat, ctx)
	return (base + a.flat) * (1.0 + a.increased) * a.more


## For stats that are themselves bonuses on a base multiplier (weakpoint_damage, crit_damage):
## "+20% weak-point damage" means the bonus grows by 0.20, so flat and increased both add.
func get_bonus(stat: String, ctx: Dictionary = {}) -> float:
	var a := aggregate(stat, ctx)
	return (a.flat + a.increased) * a.more


## hit: {crit: bool, weakpoint: bool, window_mult: float, resist: float, extra_more: Array[float]}
## Returns {amount, breakdown} so a debug overlay can print the full math per hit (GDD 11).
func compute_damage(base: float, ctx: Dictionary, hit: Dictionary = {}) -> Dictionary:
	var a := aggregate("damage", ctx)
	var more: float = a.more
	for x in hit.get("extra_more", []):
		more *= 1.0 + float(x)
	var window := float(hit.get("window_mult", 1.0))
	var more_total: float = min(more * window, MORE_CAP)
	var crit_mult := 1.0
	if hit.get("crit", false):
		crit_mult = BASE_CRIT_MULT + get_bonus("crit_damage", ctx)
	var weak_mult := 1.0
	if hit.get("weakpoint", false):
		weak_mult = BASE_WEAKPOINT_MULT * (1.0 + get_bonus("weakpoint_damage", ctx))
	var resist := clampf(float(hit.get("resist", 0.0)), -1.0, 0.95)
	var amount: float = (base + a.flat) * (1.0 + a.increased) * more_total * crit_mult * weak_mult * (1.0 - resist)
	return {
		"amount": max(amount, 0.0),
		"breakdown": {
			"base": base, "flat": a.flat, "increased": a.increased, "more": more, "window": window,
			"more_total": more_total, "crit": crit_mult, "weak": weak_mult, "resist": resist,
		},
	}


func roll_crit(base_chance: float, ctx: Dictionary, rng: RandomNumberGenerator) -> bool:
	return rng.randf() < get_stat("crit_chance", base_chance, ctx)


static func format_breakdown(b: Dictionary, amount: float) -> String:
	return "(%.0f+%.0f) x%.2f inc x%.2f more(cap %.2f) x%.2f crit x%.2f weak x%.2f resist = %.1f" % [
		b.base, b.flat, 1.0 + b.increased, b.more, b.more_total, b.crit, b.weak, 1.0 - b.resist, amount]


static func conditions_met(c: Dictionary, ctx: Dictionary) -> bool:
	if c.is_empty():
		return true
	var wt: Array = ctx.get("weapon_tags", [])
	var tt: Array = ctx.get("target_tags", [])
	if c.has("weapon_tags_any") and not _any_in(c.weapon_tags_any, wt):
		return false
	if c.has("weapon_tags_all"):
		for t in c.weapon_tags_all:
			if not wt.has(t):
				return false
	if c.has("target_tags_any") and not _any_in(c.target_tags_any, tt):
		return false
	if c.has("player_state"):
		var ps: Dictionary = c.player_state
		var st: Dictionary = ctx.get("player_state", {})
		if ps.has("morale_gte") and float(st.get("morale", 0.0)) < float(ps.morale_gte):
			return false
		if ps.has("hp_lte") and float(st.get("hp_frac", 1.0)) > float(ps.hp_lte):
			return false
		if ps.has("in_damage_window") and bool(st.get("in_damage_window", false)) != bool(ps.in_damage_window):
			return false
	if c.has("coop_allies_within_m"):
		if float(ctx.get("nearest_ally_m", INF)) > float(c.coop_allies_within_m):
			return false
	return true


static func _any_in(wanted: Array, have: Array) -> bool:
	for t in wanted:
		if have.has(t):
			return true
	return false


static func _add(agg: Dictionary, m: Dictionary) -> void:
	match m.bucket:
		"flat":
			agg.flat += m.value
		"increased":
			agg.increased += m.value
		"more":
			agg.more *= 1.0 + m.value


static func _cache_key(stat: String, ctx: Dictionary) -> String:
	var wt: Array = ctx.get("weapon_tags", []).duplicate()
	var tt: Array = ctx.get("target_tags", []).duplicate()
	wt.sort()
	tt.sort()
	return "%s|%s|%s" % [stat, ",".join(PackedStringArray(wt)), ",".join(PackedStringArray(tt))]
