class_name SimNav
extends RefCounted
## Wegfolge für Controller (Wolf-KI, Regel-NPC): Bewegungsrichtung zu einem Ziel, mit A* um Hindernisse.
## Der Weg wird am Charakter zwischengespeichert und regelmäßig neu geplant.

const REPLAN_INTERVAL: float = 0.5
const WAYPOINT_REACHED: float = 0.35
const LINE_SAMPLE: float = 0.2


## Bewegungsabsicht (Länge ≤ 1) zum Ziel oder ZERO, wenn innerhalb arrive_distance.
## Bei großen Schritten (grobe Ticks) wird die Länge so gekürzt, dass das Ziel nie überschossen wird.
static func direction_toward(world: SimWorld, c: SimCharacter, goal: Vector2, dt: float, arrive_distance: float = 0.2) -> Vector2:
	var to_goal := goal - c.pos
	if to_goal.length() <= arrive_distance:
		c.path.clear()
		return Vector2.ZERO
	var map := world.map
	if line_clear(map, c.pos, goal, c.collision_radius, c.owner_id, world.data):
		c.path.clear()
		return _capped(to_goal, c, dt)
	c.path_age += dt
	# Zielzelle, auf der der Charakter stehen kann: liegt das Ziel in einem Bauteil (Anker, Depot, Werkbank),
	# führt der Weg zur Nachbarzelle – sonst scheitert die Wegsuche und der Charakter bleibt am ersten Hindernis hängen
	var goal_cell := map.nearest_free_cell(SimMap.cell_of(goal), c.owner_id, world.data)
	if goal_cell.x < 0:
		goal_cell = map.nearest_walkable_cell(SimMap.cell_of(goal))
	if goal_cell != c.path_goal or c.path_age >= REPLAN_INTERVAL or c.path.is_empty():
		c.path = map.find_path(SimMap.cell_of(c.pos), goal_cell, 4000, c.owner_id, world.data)
		c.path_goal = goal_cell
		c.path_age = 0.0
	while not c.path.is_empty() and c.pos.distance_to(SimMap.cell_center(c.path[0])) < WAYPOINT_REACHED:
		c.path.pop_front()
	if c.path.is_empty():
		return _capped(to_goal, c, dt)  # kein Weg bekannt: direkt versuchen, gleitet an Wänden
	return _capped(SimMap.cell_center(c.path[0]) - c.pos, c, dt)


## Richtung mit Länge ≤ 1; kürzer, wenn ein voller Schritt (move_speed * dt) über das Ziel hinausginge.
static func _capped(offset: Vector2, c: SimCharacter, dt: float) -> Vector2:
	var max_step := c.move_speed * dt
	if max_step <= 0.0:
		return offset.normalized()
	if offset.length() >= max_step:
		return offset.normalized()
	return offset / max_step


## Ist die gerade Strecke für einen Kreis mit radius frei von Hindernissen?
static func line_clear(map: SimMap, a: Vector2, b: Vector2, radius: float, owner_id: String = "", data: SimData = null) -> bool:
	var length := a.distance_to(b)
	var steps := maxi(1, ceili(length / LINE_SAMPLE))
	for i in range(1, steps + 1):
		var sample := a.lerp(b, float(i) / float(steps))
		if map.circle_blocked(sample, radius, owner_id, data):
			return false
	return true
