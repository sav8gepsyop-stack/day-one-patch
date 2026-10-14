class_name RoastJudge
extends RefCounted
## Resolves a roast counter (GDD 8.2, 8.3, 8.6). Pure functions so they can be unit-tested
## and run identically on a dedicated server later.

const CATEGORIES := ["HYPE", "LAUNCH", "LIVE", "CRAFT"]
const COUNTERS := ["RECEIPTS", "PATCH_NOTES", "PLAYER_COUNT", "MIRROR"]
const COUNTER_FOR := {"HYPE": "RECEIPTS", "LAUNCH": "PATCH_NOTES", "LIVE": "PLAYER_COUNT", "CRAFT": "MIRROR"}
const COUNTER_LABEL := {"RECEIPTS": "RECEIPTS", "PATCH_NOTES": "PATCH NOTES", "PLAYER_COUNT": "PLAYER COUNT", "MIRROR": "MIRROR"}

## [perfect_ms, good_ms] per difficulty (GDD 8.4).
const DIFFICULTY_WINDOWS := {
	"story": [250, 500], "normal": [120, 300], "hard": [90, 220], "nightmare": [60, 160],
}
const MAX_LAG_COMP_MS := 150.0

const PERFECT := "PERFECT"
const GOOD := "GOOD"
const DEFLECTED := "DEFLECTED"
const ROASTED := "ROASTED"

## Effects by result (GDD 8.3).
const OUTCOMES := {
	"PERFECT": {"window_s": 4.0, "window_mult": 2.5, "morale": -20.0, "ult": 15.0, "hype": -1},
	"GOOD": {"window_s": 2.0, "window_mult": 1.5, "morale": -10.0, "ult": 8.0, "hype": 0},
	"DEFLECTED": {"window_s": 0.0, "window_mult": 1.0, "morale": 0.0, "ult": 0.0, "hype": 0},
	"ROASTED": {"window_s": 0.0, "window_mult": 1.0, "morale": 0.0, "ult": 0.0, "hype": 1},
}
const BACKUP_WINDOW_S := 0.5
const BACKUP_MULT := 0.25
const BACKUP_MULT_CAP := 3.0
const RATIOD_STREAK := 3
const RATIOD_STUN_S := 6.0
const RATIOD_MULT := 3.0

## assist: "off" | "assisted_select" (auto counter) | "one_button" (auto timing) | "full_auto" (always GOOD).
static func judge(category: String, counter: String, has_deflect: bool, offset_ms: float,
		perfect_ms: float, good_ms: float, assist := "off") -> String:
	if assist == "full_auto":
		return GOOD
	var right: bool = counter == str(COUNTER_FOR.get(category, "")) or assist == "assisted_select"
	var timing := "miss"
	if assist == "one_button":
		timing = "good"
	elif has_deflect:
		var a: float = abs(offset_ms)
		if a <= perfect_ms:
			timing = "perfect"
		elif a <= good_ms:
			timing = "good"
	if right and timing == "perfect":
		return PERFECT
	if right and timing == "good":
		return GOOD
	if right or timing != "miss":
		return DEFLECTED
	return ROASTED


## Back Up (non-targeted co-op players): same inputs, windows halved. Success = PERFECT or GOOD.
static func judge_backup(category: String, counter: String, has_deflect: bool, offset_ms: float,
		perfect_ms: float, good_ms: float, assist := "off") -> String:
	return judge(category, counter, has_deflect, offset_ms, perfect_ms * 0.5, good_ms * 0.5, assist)


static func windows_for(difficulty: String) -> Array:
	return DIFFICULTY_WINDOWS.get(difficulty, DIFFICULTY_WINDOWS.normal)


## Server-side conversion of a client's deflect timestamp. The client may claim its press
## happened up to min(RTT/2, 150 ms) before the packet arrived, never earlier and never later.
static func compensate(claimed_server_ms: float, arrival_server_ms: float, rtt_ms: float) -> float:
	var comp: float = min(rtt_ms * 0.5, MAX_LAG_COMP_MS)
	return clampf(claimed_server_ms, arrival_server_ms - comp, arrival_server_ms)


## Combines the primary result with Back Up successes into the final damage window.
static func damage_window(primary: String, backup_successes: int) -> Dictionary:
	var o: Dictionary = OUTCOMES[primary]
	var dur: float = o.window_s
	var mult: float = o.window_mult
	if dur > 0.0 and backup_successes > 0:
		dur += BACKUP_WINDOW_S * backup_successes
		mult = min(mult + BACKUP_MULT * backup_successes, BACKUP_MULT_CAP)
	return {"duration_s": dur, "mult": mult}
