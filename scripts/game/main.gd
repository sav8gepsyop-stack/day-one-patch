extends Node3D
## Root of the game: builds the arena and UI, starts sessions from the menu or command line.

static var last_end_reason := ""

var arena: Arena
var hud: Hud
var roast_ui: RoastUi
var tree_ui: TreeUi
var menu: MainMenu


func _ready() -> void:
	arena = Arena.new()
	arena.name = "Arena"
	add_child(arena)
	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	hud = Hud.new()
	hud.arena = arena
	ui.add_child(hud)
	roast_ui = RoastUi.new()
	ui.add_child(roast_ui)
	var overlay := CanvasLayer.new()
	overlay.name = "Overlay"
	overlay.layer = 5
	add_child(overlay)
	tree_ui = TreeUi.new()
	overlay.add_child(tree_ui)
	var top := CanvasLayer.new()
	top.name = "Menu"
	top.layer = 10
	add_child(top)
	menu = MainMenu.new()
	top.add_child(menu)
	menu.start_requested.connect(_on_start)
	menu.leave_requested.connect(_leave)
	Net.session_started.connect(_on_session_started)
	Net.session_failed.connect(_on_session_failed)
	Net.session_ended.connect(_on_session_ended)
	arena.victory.connect(hud.show_gold_stamp)
	if last_end_reason != "":
		menu.show_main(last_end_reason)
		last_end_reason = ""
	if Game.args.has("autotest"):
		var t := AutoTest.new()
		t.name = "AutoTest"
		t.mode = str(Game.args.autotest)
		add_child(t)
	_start_from_args()


func _start_from_args() -> void:
	if Game.args.has("solo"):
		_on_start("solo", "")
	elif Game.args.has("host"):
		_on_start("host", "")
	elif Game.args.has("join"):
		_on_start("join", str(Game.args.join))
	elif Game.args.has("connect_lobby"):
		Net.join_steam_lobby(int(Game.args.connect_lobby))


func _on_start(kind: String, address: String) -> void:
	match kind:
		"solo":
			Net.start_solo()
		"host":
			var port_arg = Game.args.get("host", true)
			Net.host_enet(int(port_arg) if port_arg is String and port_arg.is_valid_int() else Net.DEFAULT_PORT)
		"join":
			Net.join_enet(address)
		"steam_host":
			Net.host_steam()


func _on_session_started(mode: String) -> void:
	menu.visible = false
	if not Game.is_headless():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if mode in ["solo", "enet_host", "steam_host"]:
		arena.start_server_game()
	else:
		arena.start_client()


func _on_session_failed(reason: String) -> void:
	menu.show_main(reason)


func _on_session_ended(reason: String) -> void:
	last_end_reason = reason
	Net.leave()
	get_tree().reload_current_scene.call_deferred()


func _leave() -> void:
	Net.leave()
	get_tree().reload_current_scene.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and arena.running:
		if tree_ui.visible:
			tree_ui.toggle()
		else:
			menu.show_pause(not menu.visible)
	elif event is InputEventMouseButton and event.pressed and arena.running and not menu.visible and not tree_ui.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
