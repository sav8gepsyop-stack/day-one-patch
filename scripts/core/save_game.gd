class_name SaveGame
extends RefCounted
## Versioned JSON save (GDD 6.2). Persistent progress is written at milestones and on
## tree purchases; quitting mid-studio keeps currencies (the GDD's player-friendly option).

const SAVE_VERSION := 3


static func default_save() -> Dictionary:
	return {
		"save_version": SAVE_VERSION,
		"milestone": 0,
		"profile": {"player_id": "", "appearance": {}, "vo_set": "A"},
		"currencies": {"studio_credits": 0, "industry_knowledge": 0, "keystone_tokens": 0},
		"toolset_tree": {"unlocked_nodes": [], "respec_count": 0, "sc_spent": 0},
		"knowledge_buffs": {"unlocked": [], "equipped": []},
		"weapons": {"owned": ["HFS", "NIB", "SCL"], "variants": {}},
		"flags": {"docs_read": []},
		"stats": {"roasts_countered": 0, "roasts_perfect": 0, "deaths": 0},
	}


static func load_save(path: String) -> Dictionary:
	var d := default_save()
	if not FileAccess.file_exists(path):
		return d
	var loaded = JsonUtil.load_file(path)
	if not (loaded is Dictionary):
		push_warning("Save at %s unreadable; starting fresh." % path)
		return d
	return migrate(_merge(d, loaded))


static func write_save(path: String, data: Dictionary) -> bool:
	data["save_version"] = SAVE_VERSION
	return JsonUtil.write_file(path, data)


static func migrate(d: Dictionary) -> Dictionary:
	# v1/v2 saves had no sc_spent; recompute lazily (0 means the first refactor fee is small).
	d.save_version = SAVE_VERSION
	return d


static func _merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in over:
		if out.has(k) and out[k] is Dictionary and over[k] is Dictionary:
			out[k] = _merge(out[k], over[k])
		else:
			out[k] = over[k]
	return out
