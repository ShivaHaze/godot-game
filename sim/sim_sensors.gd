class_name SimSensors
extends RefCounted
## Berechnet die Sensorwerte ("facts") eines Charakters aus dem Weltzustand.
## Bedingungen in data/conditions.json vergleichen diese Werte. Eine neue Bedingung, die einen
## vorhandenen Wert nutzt, braucht hier nichts; ein neuer Sensorwert ist eine Zeile in facts_for().

const FAR: float = 1.0e9  # "kein Fremder" – größer als jeder Radius
const SEARCH_RADIUS: float = 20.0  # Weiter sucht kein Sensor (größter Radius-Parameter in conditions.json)


static func facts_for(world: SimWorld, c: SimCharacter) -> Dictionary:
	var data := world.data
	return {
		"always": true,
		"health_percent": c.health_percent(),
		"is_hungry": c.hunger < data.balf("hunger.hungry_threshold"),
		"is_under_attack": is_under_attack(world, c),
		"nearest_stranger_distance": nearest_stranger_distance(world, c),
		"inventory_state": inventory_state(c, data.bali("inventory.capacity")),
		"stranger_in_claim": stranger_in_claim(world, c),
		"triggered_sensors": world.triggered_sensors_of(c.owner_id),
		"is_bleeding": world.has_effect(c, "bleeding"),
		"is_poisoned": world.has_effect(c, "poison"),
	}


static func is_under_attack(world: SimWorld, c: SimCharacter) -> bool:
	return world.time - c.last_damage_time <= world.data.balf("combat.under_attack_window")


static func inventory_state(c: SimCharacter, capacity: int) -> String:
	var count := c.inventory_count()
	if count <= 0:
		return "empty"
	if count >= capacity:
		return "full"
	return "partial"


## Nächster lebender, sichtbarer Charakter mit anderem Besitzer (Spieler oder Tier). null, wenn keiner.
static func nearest_stranger(world: SimWorld, c: SimCharacter) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := INF
	for other: SimCharacter in world.spatial.query(c.pos, SEARCH_RADIUS):
		if other == c or other.dead or other.hidden or other.owner_id == c.owner_id:
			continue
		var d := other.pos.distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = other
	return best


## Steht ein sichtbarer Fremder auf einer Kachel des eigenen Claims?
static func stranger_in_claim(world: SimWorld, c: SimCharacter) -> bool:
	var claim := world.claims.claim_of_owner(c.owner_id)
	if claim == null:
		return false
	for other: SimCharacter in world.characters.values():
		if other == c or other.dead or other.hidden or other.owner_id == c.owner_id:
			continue
		if claim.tiles.has(SimMap.cell_of(other.pos)):
			return true
	return false


static func nearest_stranger_distance(world: SimWorld, c: SimCharacter) -> float:
	var stranger := nearest_stranger(world, c)
	return stranger.pos.distance_to(c.pos) if stranger != null else FAR
