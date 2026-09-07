class_name SimMap
extends RefCounted
## Kachelkarte der Simulation: Begehbarkeit, Rohstoffquellen, Kollision, Wegsuche. Keine Nodes.
## Koordinaten in Kacheleinheiten: Zelle (x, y) belegt [x, x+1) × [y, y+1), Mitte bei (x+0.5, y+0.5).

const MOVE_SUBSTEP: float = 0.25  # Maximale Schrittweite pro Kollisionsprüfung (verhindert Tunneln bei groben Ticks)

const NEIGHBORS_4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const NEIGHBORS_DIAG: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

var width: int = 0
var height: int = 0
var tile_ids: Array[String] = []
var walkable: PackedByteArray = PackedByteArray()
var nodes: Dictionary = {}  # Vector2i -> SimResourceNode


func _init(data: SimData) -> void:
	width = data.map_width
	height = data.map_height
	tile_ids = data.map_tile_ids.duplicate()
	walkable.resize(width * height)
	for y in height:
		for x in width:
			var def := data.tile_def_at(x, y)
			walkable[y * width + x] = 1 if def.get("walkable", false) else 0
			if def.has("resource"):
				var node := SimResourceNode.new()
				node.cell = Vector2i(x, y)
				node.resource = String(def["resource"])
				node.max_amount = int(def["amount"])
				node.amount = node.max_amount
				nodes[node.cell] = node


static func cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x), floori(pos.y))


static func cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell) + Vector2(0.5, 0.5)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


func is_walkable(cell: Vector2i) -> bool:
	return in_bounds(cell) and walkable[cell.y * width + cell.x] == 1


func tile_id(cell: Vector2i) -> String:
	return tile_ids[cell.y * width + cell.x] if in_bounds(cell) else "obstacle"


func node_at(cell: Vector2i) -> SimResourceNode:
	return nodes.get(cell)


## Nächste Quelle (optional nur eines Rohstoffs) innerhalb max_dist um pos; null, wenn keine.
func nearest_node(pos: Vector2, max_dist: float, resource: String = "", require_stock: bool = false) -> SimResourceNode:
	var best: SimResourceNode = null
	var best_d := max_dist * max_dist
	for node: SimResourceNode in nodes.values():
		if not resource.is_empty() and node.resource != resource:
			continue
		if require_stock and node.amount <= 0:
			continue
		var d := node.center().distance_squared_to(pos)
		if d <= best_d:
			best_d = d
			best = node
	return best


## Prüft, ob ein Kreis (Charakterkörper) eine nicht begehbare Kachel berührt.
func circle_blocked(pos: Vector2, radius: float) -> bool:
	var min_cell := cell_of(pos - Vector2(radius, radius))
	var max_cell := cell_of(pos + Vector2(radius, radius))
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			if is_walkable(Vector2i(x, y)):
				continue
			var closest := Vector2(clampf(pos.x, x, x + 1), clampf(pos.y, y, y + 1))
			if closest.distance_squared_to(pos) < radius * radius:
				return true
	return false


## Bewegt einen Kreis um delta und gleitet an Wänden entlang (Achsen getrennt). Große Schritte werden unterteilt.
func resolve_move(from: Vector2, delta: Vector2, radius: float) -> Vector2:
	var pos := from
	var steps := maxi(1, ceili(delta.length() / MOVE_SUBSTEP))
	var part := delta / steps
	for i in steps:
		pos = _move_axis(pos, Vector2(part.x, 0.0), radius)
		pos = _move_axis(pos, Vector2(0.0, part.y), radius)
	return pos


## Bewegt entlang einer Achse; bei Kollision per Bisektion bis dicht an die Wand.
func _move_axis(pos: Vector2, delta: Vector2, radius: float) -> Vector2:
	if delta == Vector2.ZERO:
		return pos
	if not circle_blocked(pos + delta, radius):
		return pos + delta
	var lo := 0.0
	var hi := 1.0
	for i in 5:
		var mid := (lo + hi) * 0.5
		if circle_blocked(pos + delta * mid, radius):
			hi = mid
		else:
			lo = mid
	return pos + delta * lo


## Nächste begehbare Zelle um cell (Ringsuche bis max_ring). Für Ziele auf Quellen/Hindernissen.
func nearest_walkable_cell(cell: Vector2i, max_ring: int = 3) -> Vector2i:
	if is_walkable(cell):
		return cell
	for ring in range(1, max_ring + 1):
		var best := Vector2i(-1, -1)
		var best_d := 1e9
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var candidate := cell + Vector2i(dx, dy)
				if is_walkable(candidate):
					var d := Vector2(dx, dy).length_squared()
					if d < best_d:
						best_d = d
						best = candidate
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## A* auf dem Raster, 8 Richtungen ohne Eckenschneiden. Ergebnis: Zellen nach dem Start bis einschließlich Ziel.
## Leer, wenn kein Weg existiert oder Start == Ziel.
func find_path(from_cell: Vector2i, to_cell: Vector2i, max_expansions: int = 4000) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not is_walkable(from_cell) or not is_walkable(to_cell) or from_cell == to_cell:
		return result
	var open: Array[Vector2i] = [from_cell]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {from_cell: 0.0}
	var f_score: Dictionary = {from_cell: _heuristic(from_cell, to_cell)}
	var closed: Dictionary = {}
	var expansions := 0
	while not open.is_empty() and expansions < max_expansions:
		expansions += 1
		var best_index := 0
		var best_f: float = f_score[open[0]]
		for i in range(1, open.size()):
			var f: float = f_score[open[i]]
			if f < best_f:
				best_f = f
				best_index = i
		var current: Vector2i = open[best_index]
		open.remove_at(best_index)
		if current == to_cell:
			var cell := current
			while cell != from_cell:
				result.push_front(cell)
				cell = came_from[cell]
			return result
		closed[current] = true
		for step: Vector2i in NEIGHBORS_4:
			_consider(current, current + step, 1.0, to_cell, open, came_from, g_score, f_score, closed)
		for step: Vector2i in NEIGHBORS_DIAG:
			# Kein Eckenschneiden: beide orthogonalen Nachbarn müssen frei sein
			if is_walkable(current + Vector2i(step.x, 0)) and is_walkable(current + Vector2i(0, step.y)):
				_consider(current, current + step, 1.41421356, to_cell, open, came_from, g_score, f_score, closed)
	return result


func _consider(current: Vector2i, neighbor: Vector2i, cost: float, goal: Vector2i, open: Array[Vector2i], came_from: Dictionary, g_score: Dictionary, f_score: Dictionary, closed: Dictionary) -> void:
	if closed.has(neighbor) or not is_walkable(neighbor):
		return
	var tentative: float = g_score[current] + cost
	if g_score.has(neighbor) and tentative >= g_score[neighbor]:
		return
	came_from[neighbor] = current
	g_score[neighbor] = tentative
	f_score[neighbor] = tentative + _heuristic(neighbor, goal)
	if not open.has(neighbor):
		open.append(neighbor)


static func _heuristic(a: Vector2i, b: Vector2i) -> float:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return maxi(dx, dy) + 0.41421356 * mini(dx, dy)
