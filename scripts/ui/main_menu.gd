class_name MainMenu
extends Control
## Title screen: solo, LAN/direct co-op (ENet) and Steam lobbies (GodotSteam).

signal start_requested(kind: String, address: String)
signal leave_requested

var _status: Label
var _name: LineEdit
var _ip: LineEdit
var _steam_host: Button
var _steam_invite: Button
var _main_box: Control
var _pause_box: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.03, 0.09, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var stack := VBoxContainer.new()
	center.add_child(stack)
	_main_box = _build_main()
	stack.add_child(_main_box)
	_pause_box = _build_pause()
	stack.add_child(_pause_box)
	_pause_box.visible = false
	Net.steam_lobby_changed.connect(func(_id): _steam_invite.disabled = false)


func _build_main() -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(560, 0)
	v.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "DAY ONE PATCH"
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color("#ffd23f"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := Label.new()
	sub.text = "A Code Crusader Story · Vertical Slice: Saccharine Toddler Inc."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color("#ff4fd8"))
	v.add_child(sub)
	_name = _field(v, "Handle", str(Game.settings.player_name))
	var diff := _option(v, "Difficulty", ["story", "normal", "hard", "nightmare"], str(Game.settings.difficulty))
	diff.item_selected.connect(func(i): _set_setting("difficulty", diff.get_item_text(i)))
	var assist := _option(v, "Comeback assist", ["off", "assisted_select", "one_button", "full_auto"], str(Game.settings.comeback_assist))
	assist.item_selected.connect(func(i): _set_setting("comeback_assist", assist.get_item_text(i)))
	_button(v, "Play Solo", func(): _go("solo", ""))
	_button(v, "Host Co-op (LAN / direct IP, port %d)" % Net.DEFAULT_PORT, func(): _go("host", ""))
	var row := HBoxContainer.new()
	_ip = LineEdit.new()
	_ip.text = str(Game.settings.last_ip)
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_ip)
	var jb := Button.new()
	jb.text = "Join"
	jb.pressed.connect(func(): _go("join", _ip.text))
	row.add_child(jb)
	v.add_child(row)
	_steam_host = _button(v, "Host Steam Lobby (friends only)", func(): _go("steam_host", ""))
	_steam_invite = _button(v, "Invite Steam Friends", func(): Net.invite_steam_friends())
	_steam_invite.disabled = true
	_steam_host.disabled = not Net.steam_ready
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.text = Net.steam_status
	_status.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	v.add_child(_status)
	_button(v, "Quit", func(): get_tree().quit())
	return v


func _build_pause() -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(420, 0)
	var t := Label.new()
	t.text = "PAUSED (co-op keeps running)"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 28)
	v.add_child(t)
	_button(v, "Resume", func(): show_pause(false))
	_button(v, "Invite Steam Friends", func(): Net.invite_steam_friends())
	_button(v, "Leave Session", func(): leave_requested.emit())
	return v


func show_pause(on: bool) -> void:
	visible = on
	_main_box.visible = false
	_pause_box.visible = on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if on else Input.MOUSE_MODE_CAPTURED
	if Player.local:
		Player.local.input_enabled = not on


func show_main(status := "") -> void:
	visible = true
	_main_box.visible = true
	_pause_box.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if status != "":
		set_status(status)


func set_status(t: String) -> void:
	_status.text = t


func _set_setting(key: String, value: Variant) -> void:
	Game.settings[key] = value
	Game.save_settings()


func _go(kind: String, address: String) -> void:
	if kind == "join":
		Game.settings.last_ip = address
	Game.settings.player_name = _name.text.strip_edges().substr(0, 24)
	Game.save_settings()
	set_status("Starting %s..." % kind)
	start_requested.emit(kind, address)


func _field(parent: Control, label: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(e)
	parent.add_child(row)
	return e


func _option(parent: Control, label: String, items: Array, current: String) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(160, 0)
	row.add_child(l)
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.selected = max(0, items.find(current))
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(o)
	parent.add_child(row)
	return o


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
