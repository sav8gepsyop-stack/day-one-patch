class_name PlayerToolsetState
extends RefCounted
## One player's tree progress and wallet (GDD 7.8). Owned by the host in co-op;
## clients send PurchaseNode(node_id) and receive the new state back.

var unlocked: Array = []
var currencies := {"studio_credits": 0, "industry_knowledge": 0, "keystone_tokens": 0}
var respec_count := 0
var sc_spent := 0


func has(id: String) -> bool:
	return unlocked.has(id)


## Returns "" when the purchase is allowed, otherwise a reason code.
func check_purchase(db: ToolsetTreeDB, id: String, milestone: int) -> String:
	var n: Dictionary = db.get_node_def(id)
	if n.is_empty():
		return "unknown_node"
	if has(id):
		return "already_unlocked"
	if milestone < n.milestone_gate:
		return "milestone_locked"
	for r in n.requires_all:
		if not has(r):
			return "missing_prereq"
	if not n.requires_any.is_empty():
		var ok := false
		for r in n.requires_any:
			ok = ok or has(r)
		if not ok:
			return "missing_prereq"
	if n.exclusive_group != "":
		for u in unlocked:
			if db.get_node_def(u).get("exclusive_group", "") == n.exclusive_group:
				return "exclusive_conflict"
	for c in n.cost:
		if int(currencies.get(c, 0)) < int(n.cost[c]):
			return "insufficient_" + c
	return ""


## Transaction: validate, deduct, add node. Caller rebuilds the resolver and saves.
func purchase(db: ToolsetTreeDB, id: String, milestone: int) -> String:
	var reason := check_purchase(db, id, milestone)
	if reason != "":
		return reason
	var n: Dictionary = db.get_node_def(id)
	for c in n.cost:
		currencies[c] = int(currencies.get(c, 0)) - int(n.cost[c])
	sc_spent += int(n.cost.studio_credits)
	unlocked.append(id)
	return ""


func add_currency(kind: String, amount: int) -> void:
	currencies[kind] = max(0, int(currencies.get(kind, 0)) + amount)


## "Refactor" fee: first is free, then 15% of total SC spent, +5% per refactor, capped at 40%.
func respec_fee() -> int:
	if respec_count == 0:
		return 0
	var pct: float = min(0.15 + 0.05 * (respec_count - 1), 0.40)
	return int(round(sc_spent * pct))


## Refunds everything spent minus the fee; keystones refund their token.
func respec(db: ToolsetTreeDB) -> int:
	var fee := respec_fee()
	var refund := {"studio_credits": 0, "industry_knowledge": 0, "keystone_tokens": 0}
	for id in unlocked:
		var cost: Dictionary = db.get_node_def(id).get("cost", {})
		for c in refund:
			refund[c] += int(cost.get(c, 0))
	refund.studio_credits = max(0, refund.studio_credits - fee)
	for c in refund:
		add_currency(c, refund[c])
	unlocked.clear()
	sc_spent = 0
	respec_count += 1
	return fee


## Drops unknown nodes and nodes whose prerequisites are missing (host check on join).
func sanitize(db: ToolsetTreeDB) -> PackedStringArray:
	var dropped := PackedStringArray()
	var changed := true
	while changed:
		changed = false
		for id in unlocked.duplicate():
			var n: Dictionary = db.get_node_def(id)
			var ok := not n.is_empty()
			if ok:
				for r in n.requires_all:
					ok = ok and unlocked.has(r)
				if not n.requires_any.is_empty():
					var any_ok := false
					for r in n.requires_any:
						any_ok = any_ok or unlocked.has(r)
					ok = ok and any_ok
			if not ok:
				unlocked.erase(id)
				dropped.append(id)
				changed = true
	return dropped


func to_dict() -> Dictionary:
	return {
		"unlocked_nodes": unlocked.duplicate(),
		"respec_count": respec_count,
		"sc_spent": sc_spent,
		"currencies": currencies.duplicate(),
	}


static func from_dict(d: Dictionary) -> PlayerToolsetState:
	var s := PlayerToolsetState.new()
	for id in d.get("unlocked_nodes", []):
		s.unlocked.append(str(id))
	s.respec_count = int(d.get("respec_count", 0))
	s.sc_spent = int(d.get("sc_spent", 0))
	var c: Dictionary = d.get("currencies", {})
	for k in s.currencies:
		s.currencies[k] = max(0, int(c.get(k, 0)))
	return s
