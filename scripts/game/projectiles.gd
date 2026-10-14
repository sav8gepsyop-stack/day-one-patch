class_name ProjectileSystem
extends Node3D
## Lightweight projectiles. The host simulates and resolves hits; every peer gets a spawn
## message and flies a matching visual locally, so no per-frame network traffic is needed.

const KINDS := {
	"stress_ball": {"color": "#ff4fd8", "radius": 0.18, "gravity": 6.0, "ttl": 3.0},
	"talking_point": {"color": "#18c5b5", "radius": 0.25, "gravity": 0.0, "ttl": 3.5, "label": "\"SYNERGY\""},
	"icebreaker": {"color": "#a8e6ff", "radius": 0.3, "gravity": 0.0, "ttl": 4.0},
	"scope_creep": {"color": "#c38bff", "radius": 0.28, "gravity": 4.0, "ttl": 4.0},
}

var arena: Arena
var _next_id := 1
var _live: Dictionary = {}   # id -> entry


func spawn(kind: String, pos: Vector3, vel: Vector3, team: String, payload: Dictionary) -> void:
	var id := _next_id
	_next_id += 1
	_live[id] = {"id": id, "kind": kind, "pos": pos, "vel": vel, "team": team, "payload": payload, "ttl": float(KINDS[kind].ttl)}
	_fx_spawn.rpc(id, kind, pos, vel)


@rpc("authority", "call_local", "reliable")
func _fx_spawn(id: int, kind: String, pos: Vector3, vel: Vector3) -> void:
	var k: Dictionary = KINDS[kind]
	var node := Fx.sphere(float(k.radius), Color(k.color), Vector3.ZERO, true)
	if k.has("label"):
		var l := Fx.label(str(k.label), Color(k.color), Vector3(0, 0.4, 0), 28)
		node.add_child(l)
	add_child(node)
	node.global_position = pos
	if multiplayer.is_server() and _live.has(id):
		_live[id].node = node
	else:
		_live[id] = {"id": id, "kind": kind, "pos": pos, "vel": vel, "node": node, "ttl": float(k.ttl), "visual_only": true}


@rpc("authority", "call_local", "reliable")
func _fx_end(id: int, pos: Vector3, kind: String) -> void:
	var e: Dictionary = _live.get(id, {})
	if e.has("node") and is_instance_valid(e.node):
		e.node.queue_free()
	_live.erase(id)
	Fx.burst(arena.fx_root, pos, 0.6, Color(KINDS.get(kind, KINDS.stress_ball).color), 0.25)


func _physics_process(delta: float) -> void:
	var server := multiplayer.is_server()
	for id in _live.keys():
		var e: Dictionary = _live[id]
		var k: Dictionary = KINDS[e.kind]
		var from: Vector3 = e.pos
		e.vel += Vector3.DOWN * float(k.gravity) * delta
		var to: Vector3 = from + e.vel * delta
		e.pos = to
		e.ttl -= delta
		if e.has("node") and is_instance_valid(e.node):
			e.node.global_position = to
		if e.get("visual_only", false):
			if e.ttl < -0.5:  # host end message lost or late: clean up anyway
				if is_instance_valid(e.get("node")):
					e.node.queue_free()
				_live.erase(id)
			continue
		if not server:
			continue
		var hit := _sweep(e, from, to, float(k.radius))
		if not hit.is_empty():
			_impact(e, hit.pos, hit.get("target"))
		elif e.ttl <= 0.0:
			_impact(e, to, null)


func _sweep(e: Dictionary, from: Vector3, to: Vector3, radius: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var mask := Layers.WORLD if e.team == "enemy" else Layers.SHOT_MASK
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.collide_with_areas = e.team != "enemy"
	var r := space.intersect_ray(q)
	if e.team == "enemy":
		for p in arena.alive_players():
			var c: Vector3 = p.global_position + Vector3.UP * 0.9
			if Geometry3D.get_closest_point_to_segment(c, from, to).distance_to(c) <= radius + 0.55:
				return {"pos": c, "target": p}
	if r.is_empty():
		return {}
	var col: Object = r.collider
	return {"pos": r.position, "target": col.get_meta("hit_owner") if col.has_meta("hit_owner") else null}


func _impact(e: Dictionary, pos: Vector3, target: Variant) -> void:
	_fx_end.rpc(e.id, pos, e.kind)
	_live.erase(e.id)
	arena.on_projectile_impact(e, pos, target)
