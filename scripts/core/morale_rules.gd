class_name MoraleRules
extends RefCounted
## Morale ("Burnout") thresholds and effects (GDD 5).

const MAX := 100.0
const CRUNCH_DURATION_S := 6.0
const CRUNCH_RESET_TO := 60.0
const CRUNCH_DAMAGE_MORE := 0.5
const CRUNCH_TAKEN_MULT := 1.5
const KILL_RELIEF := -1.0
const COFFEE_RELIEF := -25.0


static func band(morale: float, crunch_active := false) -> String:
	if crunch_active or morale >= MAX:
		return "crunch"
	if morale >= 80.0:
		return "burnt"
	if morale >= 50.0:
		return "fatigued"
	return "normal"


## Multiplier on reload time.
static func reload_time_mult(b: String) -> float:
	match b:
		"fatigued":
			return 1.1
		"burnt":
			return 1.2
	return 1.0


## "20% slower everything" while Burnt.
static func speed_mult(b: String) -> float:
	return 0.8 if b == "burnt" else 1.0


static func label(b: String) -> String:
	match b:
		"fatigued":
			return "FATIGUED"
		"burnt":
			return "BURNT"
		"crunch":
			return "CRUNCH STATE"
	return "OK"
