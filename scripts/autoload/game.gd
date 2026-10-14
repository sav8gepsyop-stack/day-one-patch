extends Node
## Local settings, profile/save, input map and command-line options.
##
## Command-line (after "--"): --solo | --host[=port] | --join=ip[:port] | --name=Nick
##   --difficulty=story|normal|hard|nightmare  --assist=off|assisted_select|one_button|full_auto
##   --start=boss (skip waves)  --autotest=solo|host|client  --save=user://other.json
##   +connect_lobby <id> (Steam invite launch)

signal settings_changed

const DEFAULT_SAVE_PATH := "user://save.json"
const SETTINGS_PATH := "user://settings.json"

var args: Dictionary = {}
var save_path := DEFAULT_SAVE_PATH
var save: Dictionary = {}
var settings := {
	"player_name": "Crusader",
	"difficulty": "normal",
	"comeback_assist": "off",
	"mouse_sensitivity": 0.0025,
	"streamer_mode": false,
	"last_ip": "127.0.0.1",
}


func _ready() -> void:
	_parse_args()
	_load_settings()
	var default_path := DEFAULT_SAVE_PATH
	if args.has("autotest"):
		default_path = "user://autotest_%s.json" % str(args.autotest)  # never touch a real save
		if not args.has("save") and FileAccess.file_exists(default_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(default_path))
	save_path = str(args.get("save", default_path))
	save = SaveGame.load_save(save_path)
	if args.has("name"):
		settings.player_name = str(args.name)
	if args.has("difficulty"):
		settings.difficulty = str(args.difficulty)
	if args.has("assist"):
		settings.comeback_assist = str(args.assist)
	_setup_input()


func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func write_save() -> void:
	SaveGame.write_save(save_path, save)


func save_settings() -> void:
	JsonUtil.write_file(SETTINGS_PATH, settings)
	settings_changed.emit()


## Profile sent to the host on join: the host validates it and owns it for the session.
func profile_for_host() -> Dictionary:
	return {
		"name": str(settings.player_name).substr(0, 24),
		"assist": settings.comeback_assist,
		"content_hash": Data.content_hash(),
		"milestone": int(save.milestone),
		"toolset": {
			"unlocked_nodes": save.toolset_tree.get("unlocked_nodes", []),
			"respec_count": save.toolset_tree.get("respec_count", 0),
			"sc_spent": save.toolset_tree.get("sc_spent", 0),
			"currencies": save.currencies,
		},
		"docs_read": save.flags.get("docs_read", []),
	}


## Called when the host confirms a tree purchase or a milestone; each player keeps their own save.
func store_toolset(state: Dictionary, milestone: int) -> void:
	save.toolset_tree.unlocked_nodes = state.get("unlocked_nodes", [])
	save.toolset_tree.respec_count = state.get("respec_count", 0)
	save.toolset_tree.sc_spent = state.get("sc_spent", 0)
	save.currencies = state.get("currencies", save.currencies)
	save.milestone = max(int(save.milestone), milestone)
	write_save()


func _load_settings() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		var s = JsonUtil.load_file(SETTINGS_PATH)
		if s is Dictionary:
			for k in s:
				settings[k] = s[k]


func _parse_args() -> void:
	var raw := OS.get_cmdline_user_args()
	var all := OS.get_cmdline_args()
	var i := all.find("+connect_lobby")
	if i >= 0 and i + 1 < all.size():
		args["connect_lobby"] = all[i + 1]
	for a in raw:
		if not a.begins_with("--"):
			continue
		var kv := a.substr(2).split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else true


func _setup_input() -> void:
	_bind("move_forward", [KEY_W, KEY_UP])
	_bind("move_back", [KEY_S, KEY_DOWN])
	_bind("move_left", [KEY_A, KEY_LEFT])
	_bind("move_right", [KEY_D, KEY_RIGHT])
	_bind("jump", [KEY_SPACE], [], [JOY_BUTTON_A])
	_bind("sprint", [KEY_SHIFT], [], [JOY_BUTTON_LEFT_STICK])
	_bind("fire", [], [MOUSE_BUTTON_LEFT])
	_bind("deflect", [KEY_E], [MOUSE_BUTTON_RIGHT], [JOY_BUTTON_RIGHT_SHOULDER])
	_bind("reload", [KEY_R], [], [JOY_BUTTON_X])
	_bind("interact", [KEY_F], [], [JOY_BUTTON_B])
	_bind("ultimate", [KEY_Q], [], [JOY_BUTTON_LEFT_SHOULDER])
	_bind("next_weapon", [KEY_X], [MOUSE_BUTTON_WHEEL_DOWN], [JOY_BUTTON_Y])
	_bind("prev_weapon", [KEY_Z], [MOUSE_BUTTON_WHEEL_UP])
	# Number keys: weapon select normally; Comeback Wheel during a roast; dialogue choice after a NIB stun.
	_bind("slot_1", [KEY_1], [], [JOY_BUTTON_DPAD_UP])
	_bind("slot_2", [KEY_2], [], [JOY_BUTTON_DPAD_RIGHT])
	_bind("slot_3", [KEY_3], [], [JOY_BUTTON_DPAD_DOWN])
	_bind("slot_4", [KEY_4], [], [JOY_BUTTON_DPAD_LEFT])
	_bind("toggle_tree", [KEY_TAB], [], [JOY_BUTTON_BACK])
	_bind("debug_overlay", [KEY_F3])
	_bind("debug_credits", [KEY_F5])
	_bind("pause", [KEY_ESCAPE], [], [JOY_BUTTON_START])
	_bind_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_bind_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_bind_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_bind_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_bind_axis("fire", JOY_AXIS_TRIGGER_RIGHT, 1.0)


func _bind(action: String, keys: Array, mouse: Array = [], joy: Array = []) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.3)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)
	for m in mouse:
		var ev := InputEventMouseButton.new()
		ev.button_index = m
		InputMap.action_add_event(action, ev)
	for j in joy:
		var ev := InputEventJoypadButton.new()
		ev.button_index = j
		InputMap.action_add_event(action, ev)


func _bind_axis(action: String, axis: int, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)
