class_name TreeUi
extends Control
## Toolset Upgrade Tree screen (GDD 7.8): five branch columns, tiers as rows, locked tiers
## show the studio that unlocks them, hover shows exact before/after numbers from the resolver.

const STUDIO_FOR_TIER := ["Start", "Saccharine Toddler Inc.", "344 Industries", "Nimbus Studios", "BioWarp"]
const TIERS_SHOWN := 5

var _grid: GridContainer
var _wallet: Label
var _detail: RichTextLabel
var _respec: Button
var _buttons: Dictionary = {}   # node id -> Button
var _refresh_t := 0.0
var _hover_id := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_to_group("tree_ui")
	visible = false
	var bg := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.04, 0.1, 0.94)
	bg.add_theme_stylebox_override("panel", sb)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 36)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "TOOLSET UPGRADE TREE"
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_wallet = Label.new()
	_wallet.add_theme_font_size_override("font_size", 20)
	_wallet.add_theme_color_override("font_color", Color("#7dff6b"))
	header.add_child(_wallet)
	_respec = Button.new()
	_respec.text = "Refactor (respec)"
	_respec.pressed.connect(_on_respec)
	header.add_child(_respec)
	var close := Button.new()
	close.text = "Close [Tab]"
	close.pressed.connect(toggle)
	header.add_child(close)

	_grid = GridContainer.new()
	_grid.columns = Data.tree.branches.size()
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_grid)
	for b in Data.tree.branches:
		var h := Label.new()
		h.text = "%s\n%s" % [b.display_name.to_upper(), b.stat_domain]
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		h.autowrap_mode = TextServer.AUTOWRAP_WORD
		h.custom_minimum_size = Vector2(150, 0)
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_theme_color_override("font_color", Color("#ff4fd8"))
		_grid.add_child(h)
	for tier in TIERS_SHOWN:
		for b in Data.tree.branches:
			var cell := VBoxContainer.new()
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var tn: Array = b.tier_names
			var tl := Label.new()
			tl.text = "T%d · %s" % [tier, tn[tier] if tier < tn.size() else ""]
			tl.add_theme_font_size_override("font_size", 13)
			tl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
			cell.add_child(tl)
			var nodes := Data.tree.nodes_in_branch_tier(b.branch, tier)
			if nodes.is_empty():
				var lock := Label.new()
				lock.text = "LOCKED · after %s" % STUDIO_FOR_TIER[min(tier, STUDIO_FOR_TIER.size() - 1)]
				lock.autowrap_mode = TextServer.AUTOWRAP_WORD
				lock.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
				cell.add_child(lock)
			for n in nodes:
				var btn := Button.new()
				btn.custom_minimum_size = Vector2(150, 40)
				btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
				btn.clip_text = true
				btn.pressed.connect(_buy.bind(n.id))
				btn.mouse_entered.connect(_on_hover.bind(n.id))
				cell.add_child(btn)
				_buttons[n.id] = btn
			_grid.add_child(cell)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	_detail.custom_minimum_size = Vector2(0, 110)
	root.add_child(_detail)


func _on_respec() -> void:
	if Player.local:
		Player.local.srv_respec.rpc_id(1)


func _on_hover(id: String) -> void:
	_hover_id = id
	_update_detail()


func toggle() -> void:
	visible = not visible
	if Player.local:
		Player.local.input_enabled = not visible
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if visible else Input.MOUSE_MODE_CAPTURED
	if visible:
		_refresh()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_tree") and Player.local and Arena.current and Arena.current.running:
		toggle()
	if not visible:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 0.25
		_refresh()


func _buy(id: String) -> void:
	if Player.local:
		Player.local.srv_purchase.rpc_id(1, id)


func _refresh() -> void:
	var p := Player.local
	if p == null:
		return
	var state := _state_from(p)
	var w: Dictionary = p.wallet
	_wallet.text = "%d SC · %d IK · %d KT · Milestone %d   " % [int(w.get("studio_credits", 0)), int(w.get("industry_knowledge", 0)), int(w.get("keystone_tokens", 0)), p.milestone]
	_respec.text = "Refactor (fee %d SC)" % state.respec_fee()
	for id in _buttons:
		var n := Data.tree.get_node_def(id)
		var btn: Button = _buttons[id]
		var reason := state.check_purchase(Data.tree, id, p.milestone)
		var cost := _cost_text(n.cost)
		if state.has(id):
			btn.text = "[x] %s" % n.name_en
			btn.modulate = Color("#7dff6b")
			btn.disabled = true
		else:
			btn.text = "%s  ·  %s" % [n.name_en, cost]
			btn.disabled = reason != "" and not reason.begins_with("insufficient")
			btn.modulate = Color.WHITE if reason == "" else (Color("#ffb347") if reason.begins_with("insufficient") else Color(0.5, 0.5, 0.55))
		btn.tooltip_text = "%s\n%s" % [n.desc_en, "" if reason == "" else "(%s)" % reason.replace("_", " ")]
	_update_detail()


func _state_from(p: Player) -> PlayerToolsetState:
	var d: Dictionary = p.toolset_view.duplicate(true)
	d["currencies"] = p.wallet
	return PlayerToolsetState.from_dict(d)


func _update_detail() -> void:
	var p := Player.local
	if p == null or _hover_id == "":
		_detail.text = "[color=#aaaaaa]Hover a node for exact before/after numbers. Core nodes chain within a branch; other nodes need their tier's Core. T1 normally unlocks after beating Studio 1 (the slice starts at Milestone 1).[/color]"
		return
	var n := Data.tree.get_node_def(_hover_id)
	var lines := PackedStringArray(["[b]%s[/b]  [color=#aaaaaa](%s · T%d · %s)[/color]" % [n.name_en, n.type, n.tier, _cost_text(n.cost)], n.desc_en])
	var unlocked: Array = p.toolset_view.get("unlocked_nodes", []).duplicate()
	var before := StatResolver.new()
	before.rebuild(Data.tree, unlocked)
	var after := StatResolver.new()
	if not unlocked.has(_hover_id):
		unlocked.append(_hover_id)
	after.rebuild(Data.tree, unlocked)
	var w: Dictionary = Data.weapons[p.current_weapon_id()]
	var ctx := {"weapon_tags": w.tags}
	for e in n.effects:
		if e.op != "stat_mod":
			if e.op == "grant_tag":
				lines.append("Unlocks: %s" % str(e.tag).replace("_", " "))
			continue
		var s := str(e.stat)
		var base := _base_for(s, w)
		var b := before.get_stat(s, base, ctx) if not _is_bonus(s) else before.get_bonus(s, ctx)
		var a := after.get_stat(s, base, ctx) if not _is_bonus(s) else after.get_bonus(s, ctx)
		var note := "" if StatResolver.conditions_met(e.get("conditions", {}), ctx) else "  [color=#888888](not active for %s)[/color]" % w.name_en
		lines.append("%s (%s): [color=#ffffff]%s -> %s[/color]%s" % [s.replace("_", " ").capitalize(), w.id, _fmt(s, b, w), _fmt(s, a, w), note])
	_detail.text = "\n".join(lines)


static func _is_bonus(s: String) -> bool:
	return s in ["weakpoint_damage", "crit_damage"]


static func _base_for(s: String, w: Dictionary) -> float:
	match s:
		"damage":
			return float(w.damage)
		"fire_rate":
			return float(w.fire_rate)
		"crit_chance":
			return float(w.get("crit_chance", 0.05))
		"max_hp":
			return Player.BASE_HP
		"charge_time":
			return float(w.get("charge_time_s", 1.0))
		"reload_speed", "morale_damage_taken", "ult_charge_rate", "move_speed", "revive_speed":
			return 1.0
	return 0.0


static func _fmt(s: String, v: float, w: Dictionary) -> String:
	match s:
		"crit_chance":
			return "%.0f%%" % (v * 100.0)
		"reload_speed":
			return "%.2fs reload" % (float(w.reload_s) / max(v, 0.01))
		"weakpoint_damage":
			return "x%.2f weak point" % (2.0 * (1.0 + v))
		"morale_damage_taken", "ult_charge_rate":
			return "%.0f%%" % (v * 100.0)
		"roast_icon_lead_ms":
			return "icon %+.0f ms earlier" % v
		"charge_time":
			return "%.2fs" % v
	return "%.1f" % v


static func _cost_text(cost: Dictionary) -> String:
	var parts := PackedStringArray()
	if int(cost.studio_credits) > 0:
		parts.append("%d SC" % int(cost.studio_credits))
	if int(cost.industry_knowledge) > 0:
		parts.append("%d IK" % int(cost.industry_knowledge))
	if int(cost.keystone_tokens) > 0:
		parts.append("%d KT" % int(cost.keystone_tokens))
	return " + ".join(parts) if not parts.is_empty() else "free"
