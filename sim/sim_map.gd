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
var zone_ids: PackedStringArray = PackedStringArray()  # Zone je Kachel ("" oder z. B. "market")
var nodes: Dictionary = {}  # Vector2i -> SimResourceNode
var buildings: Dictionary = {}       # id -> SimBuilding
var built_half: Dictionary = {}      # Halbzelle (Vector2i) -> Gebäude-Kennung
var guilds: SimGuilds = null  # gesetzt von SimWorld; Gildenmitglieder gehen durch die Türen der anderen
var built_tiles: PackedByteArray = PackedByteArray()  # je Kachel: Zahl bebauter Halbzellen (schneller Vorab-Check für Kollision und Wegsuche)


func _init(data: SimData) -> void:
	width = data.map_width
	height = data.map_height
	tile_ids = data.map_tile_ids.duplicate()
	walkable.resize(width * height)
	built_tiles.resize(width * height)
	for y in height:
		for x in width:
			var def := data.tile_def_at(x, y)
			walkable[y * width + x] = 1 if def.get("walkable", false) else 0
			zone_ids.append(String(def.get("zone", "")))
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


## Zone einer Kachel ("" = keine). Marktkacheln tragen "market".
func zone(cell: Vector2i) -> String:
	return zone_ids[cell.y * width + cell.x] if in_bounds(cell) else ""


func tile_id(cell: Vector2i) -> String:
	return tile_ids[cell.y * width + cell.x] if in_bounds(cell) else "obstacle"


func node_at(cell: Vector2i) -> SimResourceNode:
	return nodes.get(cell)


# --- Bauteile -------------------------------------------------------------

func add_building(b: SimBuilding) -> void:
	buildings[b.id] = b
	for half: Vector2i in b.cells:
		built_half[half] = b.id
		_count_tile(half, 1)


func remove_building(id: int) -> void:
	var b: SimBuilding = buildings.get(id)
	if b == null:
		return
	for half: Vector2i in b.cells:
		built_half.erase(half)
		_count_tile(half, -1)
	buildings.erase(id)


func _count_tile(half: Vector2i, delta: int) -> void:
	var cell := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
	if in_bounds(cell):
		var index := cell.y * width + cell.x
		built_tiles[index] = maxi(0, built_tiles[index] + delta)


## Liegt in dieser Kachel irgendein Bauteil? (Array-Zugriff, kein Dictionary.)
func tile_built(cell: Vector2i) -> bool:
	return in_bounds(cell) and built_tiles[cell.y * width + cell.x] > 0


func building_at_half(half: Vector2i) -> SimBuilding:
	return buildings.get(built_half.get(half, -1))


func building_at(pos: Vector2) -> SimBuilding:
	return building_at_half(SimBuilding.half_cell_of(pos))


## Blockiert diese Halbzelle den Besitzer `owner_id`? (Türen lassen ihren Besitzer durch.)
func half_blocked_for(half: Vector2i, owner_id: String, data: SimData) -> bool:
	var b := building_at_half(half)
	if b == null:
		return false
	var passable := String(data.buildings[b.part]["passable"])
	if passable == "all":
		return false
	if passable == "owner" and (b.owner_id == owner_id or (guilds != null and guilds.allied(b.owner_id, owner_id))):
		return false
	return true


## Ist die Kachel für diesen Besitzer frei von blockierenden Bauteilen? (Für die Wegsuche: eine Halbzelle reicht.)
func cell_built_for(cell: Vector2i, owner_id: String, data: SimData) -> bool:
	for dy in 2:
		for dx in 2:
			if half_blocked_for(Vector2i(cell.x * 2 + dx, cell.y * 2 + dy), owner_id, data):
				return true
	return false


## Bauteil-Halbzellen, die ein Kreis berührt; nur die für `owner_id` blockierenden.
func circle_hits_building(pos: Vector2, radius: float, owner_id: String, data: SimData) -> bool:
	if built_half.is_empty():
		return false
	# Vorab: berührte Kacheln ohne Bauteil -> nichts zu prüfen (der häufige Fall auf freiem Feld).
	# Bewusst ohne range()/Aufrufe: das läuft für jede Bewegung und jede Sichtlinien-Probe.
	var x0 := floori(pos.x - radius)
	var x1 := floori(pos.x + radius)
	var y0 := floori(pos.y - radius)
	var y1 := floori(pos.y + radius)
	var any_built := false
	var y := y0
	while y <= y1:
		var x := x0
		while x <= x1:
			if x >= 0 and y >= 0 and x < width and y < height and built_tiles[y * width + x] > 0:
				any_built = true
			x += 1
		y += 1
	if not any_built:
		return false
	var min_half := SimBuilding.half_cell_of(pos - Vector2(radius, radius))
	var max_half := SimBuilding.half_cell_of(pos + Vector2(radius, radius))
	for hy in range(min_half.y, max_half.y + 1):
		for hx in range(min_half.x, max_half.x + 1):
			var half := Vector2i(hx, hy)
			if not half_blocked_for(half, owner_id, data):
				continue
			var closest := Vector2(clampf(pos.x, hx * 0.5, hx * 0.5 + 0.5), clampf(pos.y, hy * 0.5, hy * 0.5 + 0.5))
			if closest.distance_squared_to(pos) < radius * radius:
				return true
	return false


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


## Prüft, ob ein Kreis (Charakterkörper) eine nicht begehbare Kachel oder ein Bauteil berührt.
## owner_id/data: für Türen des eigenen Besitzers; leer = nur Kacheln prüfen.
func circle_blocked(pos: Vector2, radius: float, owner_id: String = "", data: SimData = null) -> bool:
	if data != null and circle_hits_building(pos, radius, owner_id, data):
		return true
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
func resolve_move(from: Vector2, delta: Vector2, radius: float, owner_id: String = "", data: SimData = null) -> Vector2:
	var pos := from
	var steps := maxi(1, ceili(delta.length() / MOVE_SUBSTEP))
	var part := delta / steps
	for i in steps:
		pos = _move_axis(pos, Vector2(part.x, 0.0), radius, owner_id, data)
		pos = _move_axis(pos, Vector2(0.0, part.y), radius, owner_id, data)
	return pos


## Bewegt entlang einer Achse; bei Kollision per Bisektion bis dicht an die Wand.
func _move_axis(pos: Vector2, delta: Vector2, radius: float, owner_id: String, data: SimData) -> Vector2:
	if delta == Vector2.ZERO:
		return pos
	if not circle_blocked(pos + delta, radius, owner_id, data):
		return pos + delta
	var lo := 0.0
	var hi := 1.0
	for i in 5:
		var mid := (lo + hi) * 0.5
		if circle_blocked(pos + delta * mid, radius, owner_id, data):
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


## Begehbar für einen Besitzer: Kachel frei und kein blockierendes Bauteil darin (Türen des Besitzers zählen nicht).
func is_walkable_for(cell: Vector2i, owner_id: String, data: SimData) -> bool:
	if not is_walkable(cell):
		return false
	if data == null or built_half.is_empty() or not tile_built(cell):
		return true
	return not cell_built_for(cell, owner_id, data)


## A* auf dem Raster, 8 Richtungen ohne Eckenschneiden. Ergebnis: Zellen nach dem Start bis einschließlich Ziel.
## Leer, wenn kein Weg existiert oder Start == Ziel. owner_id/data berücksichtigen Bauteile (Türen des Besitzers offen).
func find_path(from_cell: Vector2i, to_cell: Vector2i, max_expansions: int = 4000, owner_id: String = "", data: SimData = null) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	_path_owner = owner_id
	_path_data = data
	if not is_walkable_for(from_cell, owner_id, data) or not is_walkable_for(to_cell, owner_id, data) or from_cell == to_cell:
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
			if is_walkable_for(current + Vector2i(step.x, 0), _path_owner, _path_data) and is_walkable_for(current + Vector2i(0, step.y), _path_owner, _path_data):
				_consider(current, current + step, 1.41421356, to_cell, open, came_from, g_score, f_score, closed)
	return result


var _path_owner: String = ""
var _path_data: SimData = null


func _consider(current: Vector2i, neighbor: Vector2i, cost: float, goal: Vector2i, open: Array[Vector2i], came_from: Dictionary, g_score: Dictionary, f_score: Dictionary, closed: Dictionary) -> void:
	if closed.has(neighbor) or not is_walkable_for(neighbor, _path_owner, _path_data):
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
