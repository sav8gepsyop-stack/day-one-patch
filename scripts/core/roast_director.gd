class_name RoastDirector
extends RefCounted
## Decides when a boss roasts and which line it uses (GDD 8.4).

const PHASE_INTERVALS := {1: [14.0, 20.0], 2: [11.0, 16.0], 3: [8.0, 12.0]}
const MIN_GAP_S := 6.0
const NO_REPEAT_FRACTION := 0.7
const CONTEXT_BONUS := 3.0
const CONTEXT_TTL_S := 5.0
const RATING_ORDER := ["E", "T", "M"]

var boss_id := ""
var home_category := ""
var lines: Array = []
var rng := RandomNumberGenerator.new()
var clock := 0.0
var time_until_next := 0.0
var since_last := 999.0
var skip_next := false
var played_bag: Array = []
var last_played_at: Dictionary = {}   # line id -> clock
var last_line_id := ""
var _contexts: Dictionary = {}        # context tag -> seconds left


func setup(bank: Dictionary, seed_value: int = -1) -> void:
	boss_id = str(bank.get("boss_id", ""))
	home_category = str(bank.get("home_category", ""))
	lines = bank.get("lines", [])
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	reset_timer(1)


func reset_timer(phase: int) -> void:
	var iv: Array = PHASE_INTERVALS.get(phase, PHASE_INTERVALS[1])
	time_until_next = rng.randf_range(iv[0], iv[1])


## A contextual trigger (player_low_hp, player_respawned, ...) pre-empts the timer.
func notify_context(tag: String) -> void:
	_contexts[tag] = CONTEXT_TTL_S


func active_contexts() -> Array:
	return _contexts.keys()


## state: {phase, roast_active, damage_window, hype_stacks, players, max_rating}
## Returns the chosen line, or {} when no roast should start this tick.
func tick(delta: float, state: Dictionary) -> Dictionary:
	clock += delta
	since_last += delta
	time_until_next -= delta
	for k in _contexts.keys():
		_contexts[k] -= delta
		if _contexts[k] <= 0.0:
			_contexts.erase(k)
	if state.get("roast_active", false) or state.get("damage_window", false):
		return {}
	if since_last < MIN_GAP_S:
		return {}
	var phase := int(state.get("phase", 1))
	var context_hit := _contexts.size() > 0 and not _matching_lines(phase, state, true).is_empty()
	if time_until_next > 0.0 and not context_hit:
		return {}
	if skip_next:
		skip_next = false
		since_last = 0.0
		reset_timer(phase)
		return {}
	var line := pick(phase, state)
	since_last = 0.0
	reset_timer(phase)
	_contexts.clear()
	return line


func pick(phase: int, state: Dictionary) -> Dictionary:
	var eligible := _eligible(phase, state)
	if eligible.is_empty():
		return {}
	# Shuffle-bag: no repeats until 70% of eligible lines have played.
	var played_here := 0
	for l in eligible:
		if played_bag.has(l.id):
			played_here += 1
	if played_here >= ceili(eligible.size() * NO_REPEAT_FRACTION):
		played_bag.clear()
	var candidates: Array = []
	for l in eligible:
		if played_bag.has(l.id) or l.id == last_line_id:
			continue
		if clock - float(last_played_at.get(l.id, -INF)) < float(l.get("cooldown_s", 0.0)):
			continue
		candidates.append(l)
	if candidates.is_empty():
		# Small banks: fall back to the least recently played line instead of going silent.
		var oldest: Dictionary = {}
		for l in eligible:
			if l.id == last_line_id and eligible.size() > 1:
				continue
			if oldest.is_empty() or float(last_played_at.get(l.id, -INF)) < float(last_played_at.get(oldest.id, -INF)):
				oldest = l
		candidates = [oldest]
	var total := 0.0
	var weights: Array = []
	for l in candidates:
		var w := float(l.get("weight", 1.0))
		for c in l.get("context", []):
			if _contexts.has(c):
				w *= CONTEXT_BONUS
				break
		weights.append(w)
		total += w
	var r := rng.randf() * total
	var chosen: Dictionary = candidates[-1]
	for i in candidates.size():
		r -= weights[i]
		if r <= 0.0:
			chosen = candidates[i]
			break
	played_bag.append(chosen.id)
	last_played_at[chosen.id] = clock
	last_line_id = chosen.id
	return chosen


func _eligible(phase: int, state: Dictionary) -> Array:
	var out: Array = []
	var max_rating := RATING_ORDER.find(str(state.get("max_rating", "M")))
	for l in lines:
		if not l.get("phase", [1, 2, 3]).has(float(phase)) and not l.get("phase", [1, 2, 3]).has(phase):
			continue
		var cond: Dictionary = l.get("conditions", {})
		if int(state.get("hype_stacks", 0)) < int(cond.get("min_hype_stacks", 0)):
			continue
		if int(state.get("players", 1)) < int(cond.get("coop_players_min", 1)):
			continue
		if RATING_ORDER.find(str(l.get("rating", "T"))) > max_rating:
			continue
		out.append(l)
	return out


func _matching_lines(phase: int, state: Dictionary, need_context: bool) -> Array:
	var out: Array = []
	for l in _eligible(phase, state):
		if not need_context:
			out.append(l)
			continue
		for c in l.get("context", []):
			if _contexts.has(c):
				out.append(l)
				break
	return out
