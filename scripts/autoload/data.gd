extends Node
## Loads every JSON content file once at boot. Content changes need no code changes.

var tree: ToolsetTreeDB
var weapons: Dictionary = {}       # id -> def
var enemies: Dictionary = {}       # id -> def
var bosses: Dictionary = {}        # boss_id -> def
var roast_banks: Dictionary = {}   # boss_id -> bank
var levels: Dictionary = {}        # file stem -> level
var slice: Dictionary = {}


func _ready() -> void:
	load_all()


func load_all() -> void:
	tree = ToolsetTreeDB.from_files(JsonUtil.list_json("res://data/toolset"))
	for e in tree.errors:
		push_error("Toolset data: " + e)
	weapons = _index(JsonUtil.load_file("res://data/weapons/weapons.json"), "weapons", "id")
	enemies = _index(JsonUtil.load_file("res://data/enemies/enemies.json"), "enemies", "id")
	for p in JsonUtil.list_json("res://data/bosses"):
		var b = JsonUtil.load_file(p)
		if b is Dictionary:
			bosses[b.boss_id] = b
	for p in JsonUtil.list_json("res://data/roasts"):
		var r = JsonUtil.load_file(p)
		if r is Dictionary:
			roast_banks[r.boss_id] = r
	for p in JsonUtil.list_json("res://data/levels"):
		var l = JsonUtil.load_file(p)
		if l is Dictionary:
			levels[p.get_file().get_basename()] = l
	var s = JsonUtil.load_file("res://data/slice_config.json")
	slice = s if s is Dictionary else {}


## Hash of all gameplay data; host and clients must match (GDD 7.8 tree_hash, widened to all content).
func content_hash() -> String:
	return (tree.tree_hash + JSON.stringify([weapons, enemies, bosses, roast_banks, levels], "", true)).md5_text()


func level() -> Dictionary:
	return levels.get(str(slice.get("level", "open_plan_loft")), {})


func loadout() -> Array:
	return slice.get("loadout", ["HFS", "NIB", "SCL"])


static func _index(doc: Variant, key: String, id_key: String) -> Dictionary:
	var out := {}
	if doc is Dictionary:
		for item in doc.get(key, []):
			out[item[id_key]] = item
	return out
