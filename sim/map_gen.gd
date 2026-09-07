class_name MapGen
extends RefCounted
## Seedbarer Kartengenerator (Design: Karten datengetrieben, seedbar/tauschbar; Rand sicher, Zentrum wertvoll).
## Erzeugt ein map.json-Dictionary: Rand aus Hindernissen, Felsgruppen, Baumgruppen, Beerenbüsche,
## Spieler-Spawns am Rand, Wolf-Spawns innen. Garantiert zusammenhängend: was vom ersten Spawn aus
## nicht erreichbar ist, wird zu Hindernis. Reine Logik, keine Nodes.

const FLOOR: String = "."
const ROCK: String = "#"
const TREE: String = "T"
const BUSH: String = "B"
const STONE: String = "S"
const FIBER: String = "F"
const COPPER: String = "C"
const IRON: String = "I"
const COAL: String = "K"
const SULFUR: String = "X"
const SWAMP: String = "s"
const HERB: String = "H"
const PLAYER: String = "P"
const WOLF: String = "W"
const MARKET: String = "M"
const DEPOT: String = "D"
const OUTPOST: String = "O"
const OUTPOST_DEPOT: String = "R"
const MARKET_RADIUS: int = 2  # Markt = 5×5 Kacheln mit Depot in der Mitte


## Dichten je 100 Bodenzellen; Standardwerte entsprechen etwa der handgebauten 40×30-Karte.
static func generate(width: int, height: int, seed: int, rock_clusters_per_100: float = 0.25, tree_clusters_per_100: float = 0.4, bushes_per_100: float = 1.0) -> Dictionary:
	width = maxi(width, 12)
	height = maxi(height, 12)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var grid: Array[PackedStringArray] = []
	for y in height:
		var row := PackedStringArray()
		for x in width:
			row.append(ROCK if x == 0 or y == 0 or x == width - 1 or y == height - 1 else FLOOR)
		grid.append(row)
	var inner_cells := float((width - 2) * (height - 2))
	# Felsgruppen (Zufallslauf-Blobs)
	for i in int(inner_cells / 100.0 * rock_clusters_per_100):
		_blob(grid, rng, ROCK, rng.randi_range(3, 12), width, height)
	# Wälder
	for i in int(inner_cells / 100.0 * tree_clusters_per_100):
		_blob(grid, rng, TREE, rng.randi_range(2, 7), width, height)
	# Steinbrüche (selten) und Faserfelder
	for i in maxi(1, int(inner_cells / 100.0 * 0.12)):
		_blob(grid, rng, STONE, rng.randi_range(2, 5), width, height)
	for i in maxi(1, int(inner_cells / 100.0 * 0.3)):
		_blob(grid, rng, FIBER, rng.randi_range(2, 6), width, height)
	# Eisen und Kohle nur innen (Design: Mitte, offline nur mit Mine; Kohle seltener = Engpass)
	for i in maxi(2, int(inner_cells / 100.0 * 0.08)):
		_blob(grid, rng, IRON, rng.randi_range(2, 4), width, height, 0.4, 1.0)
	for i in maxi(1, int(inner_cells / 100.0 * 0.05)):
		_blob(grid, rng, COAL, rng.randi_range(2, 3), width, height, 0.4, 1.0)
	# Sümpfe (Zone: Vergiftung) mit Kräutern darin
	for i in maxi(1, int(inner_cells / 100.0 * 0.06)):
		var start := _random_floor(grid, rng, width, height, 0.1, 0.9)
		if start.x < 0:
			continue
		var cell := start
		var swamp_cells: Array[Vector2i] = []
		for step in rng.randi_range(8, 16):
			if grid[cell.y][cell.x] == FLOOR:
				grid[cell.y][cell.x] = SWAMP
				swamp_cells.append(cell)
			var next: Vector2i = cell + [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)][rng.randi_range(0, 3)]
			if next.x >= 1 and next.y >= 1 and next.x < width - 1 and next.y < height - 1:
				cell = next
		for k in mini(2, swamp_cells.size()):
			var herb := swamp_cells[rng.randi_range(0, swamp_cells.size() - 1)]
			grid[herb.y][herb.x] = HERB
	# Schwefel nur im Zentrum (Design: nur live abbaubar, wertvoll/tödlich)
	for i in maxi(1, int(inner_cells / 100.0 * 0.03)):
		_blob(grid, rng, SULFUR, rng.randi_range(2, 3), width, height, 0.65, 1.0)
	# Kupferadern nur im äußeren Ring (Design: Kupfer am Rand)
	for i in maxi(2, int(inner_cells / 100.0 * 0.1)):
		_blob(grid, rng, COPPER, rng.randi_range(2, 4), width, height, 0.0, 0.15)
	# Beerenbüsche, einzeln oder als Paar
	for i in int(inner_cells / 100.0 * bushes_per_100):
		var cell := _random_floor(grid, rng, width, height)
		if cell.x < 0:
			break
		grid[cell.y][cell.x] = BUSH
		if rng.randf() < 0.4:
			var next := cell + Vector2i(1, 0)
			if next.x < width - 1 and grid[next.y][next.x] == FLOOR:
				grid[next.y][next.x] = BUSH
	# Neutrale Märkte (Design: 3–5 je Karte, hier 1 je 3000 Kacheln, mindestens 1), weit auseinander
	var market_count := maxi(1, int(inner_cells / 3000.0))
	var markets: Array[Vector2i] = []
	for attempt in market_count * 30:
		if markets.size() >= market_count:
			break
		var center := _random_floor(grid, rng, width, height, 0.15, 0.85)
		if center.x < 0 or center.x < MARKET_RADIUS + 1 or center.y < MARKET_RADIUS + 1 or center.x >= width - MARKET_RADIUS - 1 or center.y >= height - MARKET_RADIUS - 1:
			continue
		var far := true
		for other: Vector2i in markets:
			if other.distance_to(center) < 20.0:
				far = false
		if not far:
			continue
		markets.append(center)
		for dy in range(-MARKET_RADIUS, MARKET_RADIUS + 1):
			for dx in range(-MARKET_RADIUS, MARKET_RADIUS + 1):
				grid[center.y + dy][center.x + dx] = MARKET
		grid[center.y][center.x] = DEPOT
	# Ein Räuber-Outpost (Design: kein Kampfverbot, niedrige Gebühr), fern der Märkte
	for attempt in 40:
		var center := _random_floor(grid, rng, width, height, 0.3, 1.0)
		if center.x < MARKET_RADIUS + 1 or center.y < MARKET_RADIUS + 1 or center.x >= width - MARKET_RADIUS - 1 or center.y >= height - MARKET_RADIUS - 1:
			continue
		var far := true
		for other: Vector2i in markets:
			if other.distance_to(center) < 20.0:
				far = false
		if not far:
			continue
		for dy in range(-MARKET_RADIUS, MARKET_RADIUS + 1):
			for dx in range(-MARKET_RADIUS, MARKET_RADIUS + 1):
				grid[center.y + dy][center.x + dx] = OUTPOST
		grid[center.y][center.x] = OUTPOST_DEPOT
		break
	# Spieler-Spawns am Rand (ruhig), Wolf-Spawns innen (gefährlich)
	var player_spawns := maxi(1, int(inner_cells / 400.0))
	var wolf_spawns := maxi(1, int(inner_cells / 400.0))
	var spawns: Array[Vector2i] = []
	for i in player_spawns:
		var cell := _random_floor(grid, rng, width, height, 0.0, 0.2)
		if cell.x >= 0:
			spawns.append(cell)
	if spawns.is_empty():
		spawns.append(_force_floor(grid, Vector2i(2, 2)))
	_ensure_connected(grid, spawns[0], width, height)
	for cell: Vector2i in spawns:
		grid[cell.y][cell.x] = PLAYER
	for i in wolf_spawns:
		var cell := _random_floor(grid, rng, width, height, 0.3, 1.0)
		if cell.x >= 0:
			grid[cell.y][cell.x] = WOLF
	var rows: Array = []  # normales Array (nicht Packed), damit es wie map.json geprüft wird
	for y in height:
		rows.append("".join(grid[y]))
	return {
		"_doc": "Generierte Karte (MapGen, Seed %d, %d×%d). Zeichen laut tiles.json; P = Spieler-Spawn, W = Wolf-Spawn, D = Markt-Depot, R = Outpost-Depot." % [seed, width, height],
		"width": width,
		"height": height,
		"spawn_chars": {"P": "player", "W": "wolf", "D": "depot", "R": "depot_outpost"},
		"rows": rows,
	}


## Zufallslauf-Blob aus `symbol` mit `size` Zellen, nur auf Boden, nicht am Rand.
static func _blob(grid: Array[PackedStringArray], rng: RandomNumberGenerator, symbol: String, size: int, width: int, height: int, inner_frac: float = 0.0, outer_frac: float = 1.0) -> void:
	var cell := _random_floor(grid, rng, width, height, inner_frac, outer_frac)
	if cell.x < 0:
		return
	for i in size:
		if grid[cell.y][cell.x] == FLOOR:
			grid[cell.y][cell.x] = symbol
		var step: Vector2i = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)][rng.randi_range(0, 3)]
		var next: Vector2i = cell + step
		if next.x >= 1 and next.y >= 1 and next.x < width - 1 and next.y < height - 1:
			cell = next


## Zufällige Bodenzelle; optional nur in einem Ring zwischen inner_frac und outer_frac (0 = Rand, 1 = Mitte).
static func _random_floor(grid: Array[PackedStringArray], rng: RandomNumberGenerator, width: int, height: int, inner_frac: float = 0.0, outer_frac: float = 1.0) -> Vector2i:
	for attempt in 200:
		var x := rng.randi_range(1, width - 2)
		var y := rng.randi_range(1, height - 2)
		if grid[y][x] != FLOOR:
			continue
		var edge := minf(minf(x, width - 1 - x) / (width * 0.5), minf(y, height - 1 - y) / (height * 0.5))
		if edge < inner_frac or edge > outer_frac:
			continue
		return Vector2i(x, y)
	return Vector2i(-1, -1)


static func _force_floor(grid: Array[PackedStringArray], cell: Vector2i) -> Vector2i:
	grid[cell.y][cell.x] = FLOOR
	return cell


## Flutfüllung vom Start: unerreichbare Bodenzellen werden Hindernis (kleine Taschen hinter Felsen/Bäumen).
static func _ensure_connected(grid: Array[PackedStringArray], start: Vector2i, width: int, height: int) -> void:
	var reached := {}
	var queue: Array[Vector2i] = [start]
	reached[start] = true
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_back()
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = cell + step
			if next.x < 0 or next.y < 0 or next.x >= width or next.y >= height:
				continue
			if reached.has(next) or grid[next.y][next.x] != FLOOR:
				continue
			reached[next] = true
			queue.append(next)
	for y in height:
		for x in width:
			var cell := Vector2i(x, y)
			if grid[y][x] == FLOOR and not reached.has(cell):
				grid[y][x] = ROCK
			# Quellen, die keinen begehbaren Nachbarn haben, sind unerreichbar -> Fels
			elif grid[y][x] == TREE or grid[y][x] == BUSH or grid[y][x] == STONE or grid[y][x] == FIBER:
				var accessible := false
				for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if reached.has(cell + step):
						accessible = true
				if not accessible:
					grid[y][x] = ROCK
