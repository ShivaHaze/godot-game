extends GutTest
## Karte: Begehbarkeit, Kollision mit Gleiten, Wegsuche.

var data: SimData
var map: SimMap


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	map = SimMap.new(data)


func test_walkable_and_bounds() -> void:
	assert_false(map.is_walkable(Vector2i(0, 0)), "Rand ist Hindernis")
	assert_true(map.is_walkable(data.player_spawns[0]), "Spawn ist Boden")
	assert_false(map.is_walkable(Vector2i(-1, 3)), "außerhalb")
	assert_false(map.is_walkable(Vector2i(3, 2)), "Holzquelle ist nicht begehbar")
	var expected := 0
	for row: String in data.map_rows:
		expected += row.count("T") + row.count("B") + row.count("S") + row.count("F") + row.count("C") + row.count("I") + row.count("K") + row.count("X") + row.count("H")
	assert_eq(map.nodes.size(), expected, "alle Quellen-Zeichen werden Quellen")


func test_move_into_wall_stops_before_wall() -> void:
	# Zelle (1, 1) ist Boden, (0, 1) ist Wand. Bewegung nach links muss am Rand stoppen.
	var start := Vector2(1.5, 1.5)
	var end := map.resolve_move(start, Vector2(-1.0, 0.0), 0.35)
	assert_almost_eq(end.x, 1.0 + 0.35, 0.02, "stoppt mit Radius vor der Wand")
	assert_eq(end.y, 1.5)


func test_move_slides_along_wall() -> void:
	var start := Vector2(1.5, 1.5)
	var end := map.resolve_move(start, Vector2(-1.0, 2.0), 0.35)
	assert_almost_eq(end.x, 1.35, 0.02, "x blockiert")
	assert_almost_eq(end.y, 3.5, 0.02, "y gleitet weiter")


func test_large_step_does_not_tunnel() -> void:
	# Ein-Zellen-Wand bei x = 0: aus (1.5, 5.5) 10 Kacheln nach links darf nicht durch den Rand.
	var end := map.resolve_move(Vector2(1.5, 5.5), Vector2(-10.0, 0.0), 0.35)
	assert_gt(end.x, 1.0, "bleibt diesseits der Wand")


func test_path_to_chamber_goes_through_opening() -> void:
	# Kammer bei y 10–11, x 23–26; einziger Zugang bei (24, 12).
	var path := map.find_path(data.player_spawns[0], Vector2i(24, 10))
	assert_false(path.is_empty(), "Weg gefunden")
	assert_eq(path[path.size() - 1], Vector2i(24, 10), "endet am Ziel")
	assert_true(path.has(Vector2i(24, 12)), "führt durch die Öffnung")
	var previous := data.player_spawns[0]
	for cell: Vector2i in path:
		assert_true(map.is_walkable(cell), "Wegzelle begehbar: %s" % cell)
		var step := cell - previous
		assert_true(absi(step.x) <= 1 and absi(step.y) <= 1, "Schritte sind benachbart")
		previous = cell


func test_path_to_obstacle_is_empty() -> void:
	assert_true(map.find_path(data.player_spawns[0], Vector2i(0, 0)).is_empty())


func test_nearest_walkable_cell_for_tree() -> void:
	var tree := Vector2i(3, 2)
	assert_false(map.is_walkable(tree))
	var cell := map.nearest_walkable_cell(tree)
	assert_true(map.is_walkable(cell))
	assert_true(absi(cell.x - tree.x) <= 1 and absi(cell.y - tree.y) <= 1)


func test_nearest_node_filters_resource() -> void:
	var pos := SimMap.cell_center(Vector2i(10, 7))  # neben Beerenbusch (11, 7)
	var node := map.nearest_node(pos, 1.5, "berries")
	assert_not_null(node)
	assert_eq(node.resource, "berries")
	assert_null(map.nearest_node(pos, 1.5, "wood"), "kein Holz in Reichweite")


func test_generated_maps_are_valid_and_connected() -> void:
	for seed in [1, 2, 3]:
		var raw := MapGen.generate(80, 60, seed)
		var gen_data := SimData.load_from_dir("res://data")
		var problems := gen_data.apply_map(raw)
		assert_true(problems.is_empty(), "Seed %d: %s" % [seed, problems])
		assert_gte(gen_data.player_spawns.size(), 1)
		assert_gte(gen_data.wolf_spawns.size(), 1)
		var gen_map := SimMap.new(gen_data)
		assert_gt(gen_map.nodes.size(), 20, "Quellen vorhanden")
		# Alle Bodenzellen vom Spawn aus erreichbar
		var reached := {}
		var queue: Array[Vector2i] = [gen_data.player_spawns[0]]
		reached[queue[0]] = true
		while not queue.is_empty():
			var cell: Vector2i = queue.pop_back()
			for step: Vector2i in SimMap.NEIGHBORS_4:
				var next := cell + step
				if gen_map.is_walkable(next) and not reached.has(next):
					reached[next] = true
					queue.append(next)
		var floor_cells := 0
		for y in gen_map.height:
			for x in gen_map.width:
				if gen_map.is_walkable(Vector2i(x, y)):
					floor_cells += 1
		assert_eq(reached.size(), floor_cells, "Seed %d: zusammenhängend" % seed)
		assert_eq_deep(MapGen.generate(80, 60, seed)["rows"], raw["rows"])
