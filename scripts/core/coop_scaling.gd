class_name CoopScaling
extends RefCounted
## Co-op scaling rules (GDD 10.2).

static func enemy_hp_mult(players: int) -> float:
	return 1.0 + 0.6 * max(players - 1, 0)


static func enemy_count_mult(players: int) -> float:
	return 1.0 + 0.35 * max(players - 1, 0)


static func boss_hp_mult(players: int) -> float:
	return 1.0 + 0.75 * max(players - 1, 0)


static func scaled_count(base: int, players: int) -> int:
	return int(round(base * enemy_count_mult(players)))
