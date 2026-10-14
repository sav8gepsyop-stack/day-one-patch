class_name RoastUi
extends Control
## Roast telegraph, subtitles, Comeback Wheel and the punchline ring (GDD 8.1-8.2).
## Input here becomes CounterInput{line_id, counter_type, deflect_client_time} for the host.

signal roast_began(uid: int, line: Dictionary, target_peer: int)
signal roast_finished(uid: int, primary: String, results: Dictionary, ratiod: bool)

static var instance: RoastUi = null

const CAT_COLORS := {"HYPE": Color("#ff9f1c"), "LAUNCH": Color("#ff3b3b"), "LIVE": Color("#2ec4ff"), "CRAFT": Color("#c77dff")}
const CAT_ICON_NAME := {"HYPE": "megaphone", "LAUNCH": "bug", "LIVE": "servers", "CRAFT": "paintbrush"}
const RING_START_PX := 240.0
const RING_END_PX := 34.0

var active := false
var boss: Boss
var uid := 0
var line: Dictionary = {}
var target_peer := 0
var target_name := ""
var t0 := 0.0
var windup_ms := 1200.0
var icon_reveal_ms := 700.0
var selected := ""
var deflected := false
var deflect_offset_ms := 0.0
var _result_text := ""
var _result_sub := ""
var _result_color := Color.WHITE
var _result_until := 0.0
var _font: Font


func _ready() -> void:
	instance = self
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func _exit_tree() -> void:
	if instance == self:
		instance = null


func begin(b: Boss, roast_uid: int, l: Dictionary, target: int, tname: String, t0_server_ms: float, windup: float, icon_reveal: float) -> void:
	boss = b
	uid = roast_uid
	line = l
	target_peer = target
	target_name = tname
	t0 = t0_server_ms
	windup_ms = windup
	var lead := Player.local.local_resolver.get_stat("roast_icon_lead_ms", 0.0) if Player.local else 0.0
	icon_reveal_ms = max(0.0, icon_reveal - lead)
	selected = ""
	deflected = false
	active = true
	roast_began.emit(uid, line, target_peer)


func finish(roast_uid: int, results: Dictionary, primary: String, window_s: float, mult: float, ratiod: bool, hype: int) -> void:
	if roast_uid != uid:
		return
	active = false
	roast_finished.emit(roast_uid, primary, results, ratiod)
	if primary == "CANCELLED":
		return
	var mine: Dictionary = results.get(multiplayer.get_unique_id(), {})
	var me_target := target_peer == multiplayer.get_unique_id()
	_result_text = primary
	_result_color = {"PERFECT": Color("#ffd23f"), "GOOD": Color("#7dff6b"), "DEFLECTED": Color("#cccccc"), "ROASTED": Color("#ff3b3b")}.get(primary, Color.WHITE)
	match primary:
		"PERFECT":
			_result_sub = "EGO CRACK! Weak point exposed: x%.1f damage for %.1fs" % [mult, window_s]
		"GOOD":
			_result_sub = "Flustered: x%.1f damage for %.1fs" % [mult, window_s]
		"DEFLECTED":
			_result_sub = "*shrug*"
		"ROASTED":
			_result_sub = "Boss gains Hype (%d/5)" % hype
	if ratiod:
		_result_text = "RATIO'D"
		_result_sub = "Boss stunned! x3.0 damage. Next roast skipped."
		_result_color = Color("#ff4fd8")
	if me_target and primary in ["PERFECT", "GOOD"]:
		_result_sub += "\n\"%s\"" % str(line.get("retorts", {}).get("perfect_text_en", ""))
	elif not me_target and not mine.is_empty():
		_result_sub += "\nYour Back Up: %s" % ("+0.5s window" if mine.get("ok", false) else "missed (-Morale)")
	if mine.has("offset") and float(mine.offset) != 0.0:
		_result_sub += "   (%+d ms)" % int(mine.offset)
	_result_until = Time.get_ticks_msec() / 1000.0 + 2.6


func is_accepting_input() -> bool:
	if not active or deflected:
		return false
	return Net.server_now_ms() >= t0


func select_counter(i: int) -> void:
	if i < 0 or i >= RoastJudge.COUNTERS.size():
		return
	selected = RoastJudge.COUNTERS[i]
	boss.srv_counter_input.rpc_id(1, uid, selected, -1.0)


func press_deflect() -> void:
	deflected = true
	deflect_offset_ms = Net.server_now_ms() - _punch_ms()
	boss.srv_counter_input.rpc_id(1, uid, selected, Net.now_ms())


func _punch_ms() -> float:
	return t0 + windup_ms + float(line.get("punch_ms", 0))


func _process(_delta: float) -> void:
	if active and (boss == null or not is_instance_valid(boss)):
		active = false
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	var now_s := Time.get_ticks_msec() / 1000.0
	if now_s < _result_until:
		_draw_centered(_result_text, Vector2(vp.x / 2, vp.y * 0.36), 64, _result_color)
		var y := vp.y * 0.36 + 44
		for s in _result_sub.split("\n"):
			_draw_centered(s, Vector2(vp.x / 2, y), 22, Color.WHITE)
			y += 28
	if not active:
		return
	var now := Net.server_now_ms()
	var since := now - t0
	var cat := str(line.get("category", ""))
	var col: Color = CAT_COLORS.get(cat, Color.WHITE)
	var me := multiplayer.get_unique_id()

	# Speech bubble with the category icon (shape + color + name, never color alone).
	var bw: float = min(vp.x * 0.7, 980.0)
	var bubble := Rect2(vp.x / 2 - bw / 2, 70, bw, 132)
	draw_rect(bubble, Color(0, 0, 0, 0.78))
	draw_rect(bubble, col if since >= icon_reveal_ms else Color(0.5, 0.5, 0.5), false, 3.0)
	var icon_c := bubble.position + Vector2(56, 66)
	if since >= icon_reveal_ms:
		_draw_icon(cat, icon_c, 34.0, col)
		_draw_centered(cat, icon_c + Vector2(0, 52), 16, col)
	else:
		_draw_centered("?", icon_c + Vector2(0, 14), 48, Color(0.7, 0.7, 0.7))
	var text := str(line.get("text_en", ""))
	var delivery := since - windup_ms
	var shown := ""
	if delivery > 0.0:
		# Subtitles finish exactly on the punchline so players can read before deflecting.
		var frac := clampf(delivery / maxf(float(line.get("punch_ms", 1)), 1.0), 0.0, 1.0)
		shown = text.substr(0, int(ceil(text.length() * frac)))
	else:
		shown = "(Facilitator Prime strikes a pose...)"
	_draw_wrapped(shown, Rect2(bubble.position + Vector2(112, 16), Vector2(bw - 130, 110)), 22, Color.WHITE)

	# Who is being roasted.
	var call := ""
	if target_peer == me:
		call = "YOU'RE BEING ROASTED: pick the counter, then DEFLECT on the punchline"
	else:
		call = "Hey, YOU in the hoodie, %s!  Back Up: same inputs, half window" % target_name
	_draw_centered(call, Vector2(vp.x / 2, bubble.end.y + 26), 18, Color("#fff3a0"))

	# Shrinking ring closes on the punchline.
	var punch := _punch_ms()
	var c := vp / 2
	var start := t0 + windup_ms
	if now >= start and not deflected:
		var frac := clampf((now - start) / maxf(punch - start, 1.0), 0.0, 1.3)
		var r: float = lerpf(RING_START_PX, RING_END_PX, min(frac, 1.0))
		if frac > 1.0:
			r = RING_END_PX * (1.0 - (frac - 1.0) * 2.0)
		draw_arc(c, RING_END_PX, 0, TAU, 48, Color(1, 1, 1, 0.5), 2.0)
		if r > 2.0:
			draw_arc(c, r, 0, TAU, 64, col, 4.0)
	elif deflected:
		draw_arc(c, RING_END_PX, 0, TAU, 48, Color("#7dff6b"), 4.0)
		_draw_centered("%+d ms" % int(deflect_offset_ms), c + Vector2(0, RING_END_PX + 26), 18, Color("#7dff6b"))

	# Comeback Wheel.
	var n := RoastJudge.COUNTERS.size()
	var box_w := 190.0
	var total := box_w * n + 12.0 * (n - 1)
	var x0 := vp.x / 2 - total / 2
	var y0 := vp.y - 210.0
	for i in n:
		var counter: String = RoastJudge.COUNTERS[i]
		var beats := ""
		for k in RoastJudge.COUNTER_FOR:
			if RoastJudge.COUNTER_FOR[k] == counter:
				beats = k
		var rect := Rect2(x0 + i * (box_w + 12.0), y0, box_w, 64)
		var is_sel := selected == counter
		draw_rect(rect, Color(0, 0, 0, 0.8) if not is_sel else Color(CAT_COLORS[beats], 0.55))
		draw_rect(rect, CAT_COLORS[beats], false, 3.0 if is_sel else 1.5)
		_draw_icon(beats, rect.position + Vector2(22, 32), 12.0, CAT_COLORS[beats])
		_draw_centered("[%d] %s" % [i + 1, RoastJudge.COUNTER_LABEL[counter]], rect.position + Vector2(box_w / 2 + 14, 28), 17, Color.WHITE)
		_draw_centered("beats %s" % beats, rect.position + Vector2(box_w / 2 + 14, 50), 13, Color(0.8, 0.8, 0.8))
	_draw_centered("[E] / Right Mouse = DEFLECT on the punchline", Vector2(vp.x / 2, y0 + 86), 16, Color("#ffffff"))


func _draw_icon(cat: String, c: Vector2, s: float, col: Color) -> void:
	match cat:
		"HYPE":  # megaphone -> triangle
			draw_colored_polygon(PackedVector2Array([c + Vector2(-s, -s * 0.5), c + Vector2(s, -s), c + Vector2(s, s), c + Vector2(-s, s * 0.5)]), col)
		"LAUNCH":  # bug -> circle with legs
			draw_circle(c, s * 0.7, col)
			for k in [-1, 1]:
				for j in [-0.5, 0.0, 0.5]:
					draw_line(c + Vector2(k * s * 0.6, j * s), c + Vector2(k * s * 1.1, j * s * 1.4), col, 2.0)
		"LIVE":  # server rack -> stacked squares
			for j in 3:
				draw_rect(Rect2(c + Vector2(-s * 0.8, -s + j * s * 0.7), Vector2(s * 1.6, s * 0.55)), col)
		"CRAFT":  # paintbrush -> diamond
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -s), c + Vector2(s, 0), c + Vector2(0, s), c + Vector2(-s, 0)]), col)


func _draw_centered(t: String, pos: Vector2, size: int, col: Color) -> void:
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string_outline(_font, pos - Vector2(w / 2, 0), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 6, Color(0, 0, 0, 0.9))
	draw_string(_font, pos - Vector2(w / 2, 0), t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_wrapped(t: String, rect: Rect2, size: int, col: Color) -> void:
	draw_multiline_string(_font, rect.position + Vector2(0, size), t, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, size, 4, col)
