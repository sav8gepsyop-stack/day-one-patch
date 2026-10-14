extends Node
## Combat Event Bus (GDD 7.7). Gameplay emits; tree triggers, achievements, UI and
## analytics listen. Server-side events only (the host is authoritative).
##
## Events: on_shot_fired, on_hit, on_crit, on_kill, on_reload_start, on_reload_end,
## on_ability_used, on_damage_taken, on_morale_threshold, on_roast_started,
## on_counter_success, on_counter_perfect, on_counter_fail, on_ally_downed, on_revive, on_zone_enter

signal combat_event(event: String, peer_id: int, payload: Dictionary)


func emit_event(event: String, peer_id: int, payload: Dictionary = {}) -> void:
	combat_event.emit(event, peer_id, payload)
