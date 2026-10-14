class_name Hud
extends Control
## In-game HUD, drawn immediate-mode so it stays a single readable file.

static var instance: Hud = null

const COL_HP := Color("#ff5e5e")
const COL_MORALE := Color("#ffb347")
const COL_SC := Color("#7dff6b")
const COL_GOLD := Color("#ffd23f")

var arena: Arena
var debug_overlay := false
var last_breakdown := ""
var _font: Font
var _toasts: Array = []        # [{text, color, until}]
var _gold_until := 0.0
var _quit_mask := {}           # Burnt: HUD elements "quitting"
var _quit_timer := 0.0
var _hint_until := 0.0


func _ready() -> void:
	instance = self
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_hint_until = Time.get_ticks_msec() / 1000.0 + 14.0


func _exit_tree() -> void:
	if instance == self:
		instance = null


func toast(text: String, color := Color.WHITE) -> void:
	_toasts.append({"text": text, "color": color, "until": Time.get_ticks_msec() / 1000.0 + 4.5})
	if _toasts.size() > 6:
		_toasts.pop_front()


func show_gold_stamp() -> void:
	_gold_until = Time.get_ticks_msec() / 1000.0 + 7.0


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("debug_overlay"):
		debug_overlay = not debug_overlay
	var p := Player.local
	_quit_timer -= delta
	if p and p.morale_band() == "burnt" and _quit_timer <= 0.0:
		_quit_timer = randf_range(1.5, 3.5)
		_quit_mask = {["ammo", "wallet", "flow"].pick_random(): true}
	elif p and p.morale_band() != "burnt":
		_quit_mask = {}
	queue_redraw()


func _draw() -> void:
	var vp := get_viewport_rect().size
	var p := Player.local
	var now := Time.get_ticks_msec() / 1000.0
	if arena == null or not arena.running:
		return
	if p == null:
		_text("Connecting to the host...", Vector2(vp.x / 2, vp.y / 2), 28, Color.WHITE, true)
		return
	var band := p.morale_band()

	# Morale vignette.
	var vig: float = {"normal": 0.0, "fatigued": 0.18, "burnt": 0.32, "crunch": 0.4}[band]
	if vig > 0.0:
		var vc := Color(0.6, 0.0, 0.1, vig) if band != "crunch" else Color(1.0, 0.1, 0.0, vig * (0.6 + 0.4 * sin(now * 8.0)))
		var t := 70.0
		draw_rect(Rect2(0, 0, vp.x, t), vc)
		draw_rect(Rect2(0, vp.y - t, vp.x, t), vc)
		draw_rect(Rect2(0, 0, t, vp.y), vc)
		draw_rect(Rect2(vp.x - t, 0, t, vp.y), vc)

	# Crosshair, hit marker, NIB charge.
	var c := vp / 2
	var ch := Color(1, 1, 1, 0.9)
	draw_line(c + Vector2(-10, 0), c + Vector2(-4, 0), ch, 2)
	draw_line(c + Vector2(4, 0), c + Vector2(10, 0), ch, 2)
	draw_line(c + Vector2(0, -10), c + Vector2(0, -4), ch, 2)
	draw_line(c + Vector2(0, 4), c + Vector2(0, 10), ch, 2)
	var hm := p.hit_marker_alpha()
	if hm > 0.0:
		var hc := Color(1, 0.3, 0.3, hm)
		for s in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			draw_line(c + s * 6, c + s * 13, hc, 2)
	var cf := p.charge_fraction()
	if cf > 0.0:
		draw_arc(c, 22, -PI / 2, -PI / 2 + TAU * cf, 40, Color("#7cf7ff") if cf < 1.0 else Color.WHITE, 3)
		if cf >= 1.0:
			_text("CHARGED", c + Vector2(0, 44), 14, Color.WHITE, true)

	# Vitals (bottom-left).
	var x := 30.0
	var y := vp.y - 120.0
	_bar(Rect2(x, y, 300, 22), p.hp / max(p.max_hp, 1.0), COL_HP, "HP %d / %d" % [roundi(p.hp), roundi(p.max_hp)])
	_bar(Rect2(x, y + 30, 300, 16), p.morale / 100.0, COL_MORALE, "MORALE %d  %s" % [roundi(p.morale), MoraleRules.label(band)])
	if p.has_tag("ult_available"):
		var ul := "GOLD MASTER [Q]  %d%%" % roundi(p.ult_charge) if p.ult_left <= 0.0 else "GOLD MASTER  %.1fs" % p.ult_left
		_bar(Rect2(x, y + 54, 300, 14), p.ult_charge / 100.0 if p.ult_left <= 0.0 else p.ult_left / Player.ULT_DURATION_S, COL_GOLD, ul)
	else:
		_text("GOLD MASTER locked (Build Pipeline T0)", Vector2(x, y + 66), 13, Color(0.7, 0.7, 0.7))
	var st := PackedStringArray()
	for k in p.statuses:
		st.append(str(k).to_upper())
	if p.crunch_left > 0.0:
		st.append("CRUNCH +50%% DMG DEALT/TAKEN %.1fs" % p.crunch_left)
	if not st.is_empty():
		_text(" · ".join(st), Vector2(x, y - 14), 15, Color("#ffb347"))

	# Weapon (bottom-right).
	if not _quit_mask.has("ammo"):
		var wid := p.current_weapon_id()
		var w: Dictionary = Data.weapons[wid]
		var ammo_s := "INF" if p.ult_left > 0.0 else "%d / %d" % [int(p.ammo.get(wid, 0)), int(w.magazine)]
		if p.reload_left > 0.0 and p.reload_weapon == wid:
			ammo_s = "RELOADING %.1fs" % p.reload_left
		_text(w.name_en.to_upper(), Vector2(vp.x - 30, vp.y - 96), 22, JsonUtil.color(str(w.color)), false, true)
		_text(ammo_s, Vector2(vp.x - 30, vp.y - 62), 34, Color.WHITE, false, true)
		var lo := Data.loadout()
		var slots := PackedStringArray()
		for i in lo.size():
			slots.append(("[%d %s]" if i == p.weapon_idx else " %d %s ") % [i + 1, lo[i]])
		_text("  ".join(slots), Vector2(vp.x - 30, vp.y - 30), 16, Color(0.85, 0.85, 0.85), false, true)

	# Flow + wallet (top).
	if not _quit_mask.has("flow") and not (RoastUi.instance and RoastUi.instance.active):
		_text(arena.flow_text, Vector2(30, 120 if arena.boss() else 40), 18 if arena.boss() else 20, Color.WHITE)
	if not _quit_mask.has("wallet"):
		var wl: Dictionary = p.wallet
		_text("%d SC   %d IK   %d KT   ·   Milestone %d" % [int(wl.get("studio_credits", 0)), int(wl.get("industry_knowledge", 0)), int(wl.get("keystone_tokens", 0)), p.milestone],
			Vector2(vp.x - 30, 40), 18, COL_SC, false, true)
		_text("[Tab] Toolset tree", Vector2(vp.x - 30, 64), 14, Color(0.8, 0.8, 0.8), false, true)

	# Boss bar.
	var b := arena.boss()
	if b:
		var bw := 640.0
		var r := Rect2(vp.x / 2 - bw / 2, 24, bw, 18)
		_bar(r, b.hp / max(b.max_hp, 1.0), Color("#ff4fd8"), "FACILITATOR PRIME  ·  PHASE %d" % b.phase)
		for th in b.def.phase_thresholds:
			var tx: float = r.position.x + r.size.x * float(th)
			draw_line(Vector2(tx, r.position.y - 3), Vector2(tx, r.end.y + 3), Color.WHITE, 2)
		for i in int(b.def.hype_max):
			var pc := Vector2(r.position.x + 12 + i * 22, r.end.y + 16)
			draw_circle(pc, 7, Color("#ff9f1c") if i < b.hype else Color(0.25, 0.25, 0.25))
		_text("HYPE", Vector2(r.position.x + 12 + 5 * 22 + 4, r.end.y + 21), 13, Color("#ff9f1c"))
		if b.in_window():
			_text("EGO CRACK x%.1f  %.1fs  — shoot the marker!" % [b.window_mult(), b.window_left], Vector2(vp.x / 2, r.end.y + 44), 20, COL_GOLD, true)

	# Context prompts.
	if not p.dialogue_pending.is_empty():
		_text("DIALOGUE:  [1] Agree (confetti AoE)   [2] Disagree (ragdoll)   [3] [Lie] (ally 8s)", Vector2(vp.x / 2, vp.y * 0.62), 20, Color("#7cf7ff"), true)
	if p.downed:
		_text("DOWNED — %s  ·  rollback in %.0fs" % ["waiting for a code review", p.bleed_left], Vector2(vp.x / 2, vp.y * 0.58), 28, COL_HP, true)
		if p.revive_progress > 0.0:
			_bar(Rect2(vp.x / 2 - 120, vp.y * 0.6, 240, 12), p.revive_progress, Color("#7dff6b"), "")
	else:
		for o in arena.players():
			if o != p and o.downed and o.global_position.distance_to(p.global_position) < Player.REVIVE_RANGE_M:
				_text("Hold [F] to review %s's code (revive)" % o.display_name, Vector2(vp.x / 2, vp.y * 0.62), 20, Color("#7dff6b"), true)
		var cm := JsonUtil.vec3(arena.level.coffee_machine)
		if p.global_position.distance_to(cm) < Player.INTERACT_RANGE_M:
			_text("[F] Coffee (-25 Morale)", Vector2(vp.x / 2, vp.y * 0.66), 18, Color("#c69c6d"), true)

	# Toasts.
	var ty := 120.0
	for tst in _toasts.duplicate():
		if now > tst.until:
			_toasts.erase(tst)
			continue
		var a := clampf(tst.until - now, 0.0, 1.0)
		_text(tst.text, Vector2(vp.x - 30, ty), 17, Color(tst.color, a), false, true)
		ty += 26

	# Milestone stamp.
	if now < _gold_until:
		var gc := vp / 2 + Vector2(0, -60)
		draw_set_transform(gc, -0.18, Vector2.ONE)
		draw_rect(Rect2(-260, -80, 520, 160), Color(COL_GOLD, 0.15))
		draw_rect(Rect2(-260, -80, 520, 160), COL_GOLD, false, 8)
		_text("GOLD", Vector2(0, 10), 110, COL_GOLD, true)
		_text("MILESTONE_1_SHIPPED", Vector2(0, 60), 26, COL_GOLD, true)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)

	if now < _hint_until:
		_text("WASD move · Shift sprint · Space jump · LMB fire (hold to charge the Blaster) · R reload · 1-3 / wheel weapons · F interact · Q ultimate · Tab tree · F3 debug",
			Vector2(vp.x / 2, vp.y - 14), 14, Color(1, 1, 1, clampf(_hint_until - now, 0.0, 1.0)), true)

	if debug_overlay:
		var lines := PackedStringArray([
			"FPS %d  ·  mode %s  ·  peers %d" % [Engine.get_frames_per_second(), Net.mode, multiplayer.get_peers().size()],
			"RTT %.0f ms  ·  clock offset %.1f ms" % [Net.rtt_ms, Net.server_offset_ms],
			"tree: %s" % ", ".join(PackedStringArray(p.toolset_view.get("unlocked_nodes", []))),
			"last hit: %s" % last_breakdown,
			"enemies %d  ·  flow %s wave %d" % [arena.enemies().size(), arena.flow, arena.wave],
		])
		var dy := 110.0
		for l in lines:
			_text(l, Vector2(30, dy), 14, Color("#7cf7ff"))
			dy += 18


func _bar(r: Rect2, frac: float, col: Color, label: String) -> void:
	draw_rect(r, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(frac, 0.0, 1.0), r.size.y)), col)
	draw_rect(r, Color(1, 1, 1, 0.5), false, 1.0)
	if label != "":
		_text(label, r.position + Vector2(6, r.size.y - 4), int(min(r.size.y - 2, 16)), Color.WHITE)


func _text(t: String, pos: Vector2, size: int, col: Color, centered := false, right := false) -> void:
	var w := _font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := pos
	if centered:
		at.x -= w / 2
	elif right:
		at.x -= w
	draw_string_outline(_font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0, 0, 0, col.a * 0.85))
	draw_string(_font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
