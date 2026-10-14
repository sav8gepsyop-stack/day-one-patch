class_name Fx
extends RefCounted
## Placeholder-art helpers: primitive meshes, confetti, floating text. Local-only visuals.

static var _mat_cache: Dictionary = {}


static func mat(color: Color, emissive := false, alpha := 1.0) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), emissive, alpha]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	_mat_cache[key] = m
	return m


static func box(size: Vector3, color: Color, pos := Vector3.ZERO, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat(color, emissive)
	mi.position = pos
	return mi


static func sphere(radius: float, color: Color, pos := Vector3.ZERO, emissive := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	mi.mesh = mesh
	mi.material_override = mat(color, emissive)
	mi.position = pos
	return mi


static func capsule(radius: float, height: float, color: Color, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mi.mesh = mesh
	mi.material_override = mat(color)
	mi.position = pos
	return mi


static func cylinder(radius: float, height: float, color: Color, pos := Vector3.ZERO, alpha := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mi.mesh = mesh
	mi.material_override = mat(color, false, alpha)
	mi.position = pos
	return mi


static func cone(radius: float, height: float, color: Color, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = height
	mi.mesh = mesh
	mi.material_override = mat(color)
	mi.position = pos
	return mi


static func label(text: String, color: Color, pos := Vector3.ZERO, size := 48) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.modulate = color
	l.font_size = size
	l.outline_size = 10
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.position = pos
	return l


static func static_box(size: Vector3, color: Color, pos: Vector3, layer := Layers.WORLD) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	shape.shape = bs
	body.add_child(shape)
	body.add_child(box(size, color))
	return body


## Floating text that rises and fades (kill gags, damage numbers, barks).
static func float_text(parent: Node, pos: Vector3, text: String, color: Color, size := 56, life := 1.4, rise := 1.6) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var l := label(text, color, pos, size)
	parent.add_child(l)
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position", pos + Vector3.UP * rise, life)
	tw.tween_property(l, "modulate:a", 0.0, life).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(l.queue_free)


static func confetti(parent: Node, pos: Vector3, amount := 60, spread := 1.0) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles3D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = 1.6
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 4.0 * spread
	p.initial_velocity_max = 9.0 * spread
	p.gravity = Vector3(0, -9.0, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var m := BoxMesh.new()
	m.size = Vector3(0.12, 0.02, 0.08)
	p.mesh = m
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color("#ff4fd8"), Color("#ffd23f"), Color("#3dd6ff"), Color("#7dff6b")])
	grad.offsets = PackedFloat32Array([0.0, 0.33, 0.66, 1.0])
	p.color_initial_ramp = grad
	var pm := StandardMaterial3D.new()
	pm.vertex_color_use_as_albedo = true
	p.material_override = pm
	parent.add_child(p)
	p.emitting = true
	p.get_tree().create_timer(2.5).timeout.connect(p.queue_free)


static func burst(parent: Node, pos: Vector3, radius: float, color: Color, life := 0.35) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var s := sphere(radius, color, pos, true)
	s.material_override = mat(color, true, 0.55)
	parent.add_child(s)
	s.scale = Vector3.ONE * 0.2
	var tw := s.create_tween()
	tw.tween_property(s, "scale", Vector3.ONE, life * 0.5)
	tw.tween_property(s, "scale", Vector3.ONE * 1.1, life * 0.5)
	tw.tween_callback(s.queue_free)


static func tracer(parent: Node, from: Vector3, to: Vector3, color: Color, width := 0.03, life := 0.08) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var length := from.distance_to(to)
	if length < 0.05:
		return
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, width, length)
	mi.mesh = mesh
	mi.material_override = mat(color, true)
	parent.add_child(mi)
	mi.global_position = (from + to) * 0.5
	if not from.is_equal_approx(to):
		mi.look_at(to, Vector3.UP if abs((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	mi.get_tree().create_timer(life).timeout.connect(mi.queue_free)


## Adds a MultiplayerSynchronizer that replicates the listed properties of `root`.
static func add_sync(root: Node, props: Array, on_change: Array = [], interval := 0.05) -> MultiplayerSynchronizer:
	var cfg := SceneReplicationConfig.new()
	for p in props:
		var path := NodePath(".:" + p)
		cfg.add_property(path)
		cfg.property_set_spawn(path, true)
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE if on_change.has(p) else SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	sync.replication_config = cfg
	sync.replication_interval = interval
	sync.delta_interval = interval
	root.add_child(sync)
	sync.root_path = NodePath("..")
	return sync
