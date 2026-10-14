class_name Layers
extends RefCounted
## Physics layer bits shared by every gameplay script.

const WORLD := 1      # level geometry, barriers, temporary walls
const PLAYER := 2     # player bodies
const ENEMY := 4      # enemy and boss bodies
const HITBOX := 8     # weak-point areas (raycasts collide with areas on this layer)
const TRIGGER := 16   # pickups and zones (never hit by shots)

const SHOT_MASK := WORLD | ENEMY | HITBOX
