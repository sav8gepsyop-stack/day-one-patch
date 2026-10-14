class_name ToolsetTreeDB
extends RefCounted
## Static upgrade-tree data (GDD 7.5), loaded once from res://data/toolset/*.json.
## Content is data-only: add nodes by editing JSON, no code changes needed.

const BRANCH_ORDER := ["ED", "CP", "DB", "VC", "BP"]
const NODE_TYPES := ["core", "modifier", "ability", "keystone", "bridge"]
const EFFECT_OPS := ["stat_mod", "grant_ability", "grant_tag", "trigger", "override_rule"]
const BUCKETS := ["flat", "increased", "more"]
const CURRENCIES := ["studio_credits", "industry_knowledge", "keystone_tokens"]

var branches: Array = []      # [{branch, display_name, tier_names, node_ids, ...}] in BRANCH_ORDER
var nodes: Dictionary = {}    # id -> normalized node
var tree_hash := ""           # exchanged on join to detect mismatched data versions (GDD 7.8)
var errors: PackedStringArray = []


static func from_files(paths: PackedStringArray) -> ToolsetTreeDB:
	var raw: Array = []
	var db := ToolsetTreeDB.new()
	for p in paths:
		var d = JsonUtil.load_file(p)
		if d is Dictionary:
			raw.append(d)
		else:
			db.errors.append("Could not load %s" % p)
	db.load_branches(raw)
	return db


func load_branches(raw_branches: Array) -> void:
	branches.clear()
	nodes.clear()
	raw_branches.sort_custom(func(a, b): return _branch_rank(a) < _branch_rank(b))
	for b in raw_branches:
		var code := str(b.get("branch", ""))
		var ids: Array = []
		for raw_node in b.get("nodes", []):
			var n := _normalize(raw_node, code)
			if nodes.has(n.id):
				errors.append("Duplicate node id %s" % n.id)
				continue
			nodes[n.id] = n
			ids.append(n.id)
		branches.append({
			"branch": code,
			"display_name": str(b.get("display_name", code)),
			"fantasy": str(b.get("fantasy", "")),
			"stat_domain": str(b.get("stat_domain", "")),
			"tier_names": b.get("tier_names", []),
			"node_ids": ids,
		})
	_validate()
	tree_hash = JSON.stringify(nodes, "", true).md5_text()


func get_node_def(id: String) -> Dictionary:
	return nodes.get(id, {})


func nodes_in_branch_tier(branch: String, tier: int) -> Array:
	var out: Array = []
	for b in branches:
		if b.branch == branch:
			for id in b.node_ids:
				if nodes[id].tier == tier:
					out.append(nodes[id])
	return out


func max_tier() -> int:
	var t := 0
	for id in nodes:
		t = max(t, nodes[id].tier)
	return t


static func _branch_rank(b: Dictionary) -> int:
	var i := BRANCH_ORDER.find(str(b.get("branch", "")))
	return i if i >= 0 else 99


static func _normalize(n: Dictionary, branch: String) -> Dictionary:
	var cost_in: Dictionary = n.get("cost", {})
	var cost := {}
	for c in CURRENCIES:
		cost[c] = int(cost_in.get(c, 0))
	var group = n.get("exclusive_group", null)
	var tier := int(n.get("tier", 0))
	return {
		"id": str(n.get("id", "")),
		"branch": branch,
		"tier": tier,
		"type": str(n.get("type", "core")),
		"name_key": str(n.get("name_key", "")),
		"desc_key": str(n.get("desc_key", "")),
		"name_en": str(n.get("name_en", n.get("id", ""))),
		"desc_en": str(n.get("desc_en", "")),
		"icon": str(n.get("icon", "")),
		"cost": cost,
		"requires_all": n.get("requires_all", []).duplicate(),
		"requires_any": n.get("requires_any", []).duplicate(),
		"exclusive_group": "" if group == null else str(group),
		"milestone_gate": int(n.get("milestone_gate", tier)),
		"effects": n.get("effects", []).duplicate(true),
		"ui": n.get("ui", {}),
	}


func _validate() -> void:
	for id in nodes:
		var n: Dictionary = nodes[id]
		if not NODE_TYPES.has(n.type):
			errors.append("%s: unknown type '%s'" % [id, n.type])
		for r in n.requires_all + n.requires_any:
			if not nodes.has(r):
				errors.append("%s: unknown prerequisite '%s'" % [id, r])
		for e in n.effects:
			var op := str(e.get("op", ""))
			if not EFFECT_OPS.has(op):
				errors.append("%s: unknown effect op '%s'" % [id, op])
			elif op == "stat_mod":
				if not StatResolver.STATS.has(str(e.get("stat", ""))):
					errors.append("%s: unknown stat '%s'" % [id, e.get("stat")])
				if not BUCKETS.has(str(e.get("bucket", ""))):
					errors.append("%s: unknown bucket '%s'" % [id, e.get("bucket")])
