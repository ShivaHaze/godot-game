extends GutTest
## Sensoren (Bedingung über Distanz, Ort in Regeln) und Fallen (unsichtbar für Fremde, einmalig).

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 71)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 20
	player.inventory["stone"] = 10
	player.inventory["wire"] = 5
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _sensor(origin: Vector2i = Vector2i(46, 11)) -> SimBuilding:
	var b := world.place_building(player, "sensor", origin, 0)
	assert_not_null(b, "Sensor steht")
	return b


func test_sensor_triggers_on_stranger_and_holds() -> void:
	assert_false(world.can_use(player, data.condition_def("sensor_triggered")), "vorher gesperrt")
	var s := _sensor()
	assert_true(world.can_use(player, data.condition_def("sensor_triggered")), "erster Sensor schaltet frei")
	assert_eq(s.label, "Sensor 1")
	assert_eq(player.extra_places["b%d" % s.id]["name"], "Sensor 1", "Sensor ist ein Ort")
	assert_eq(player.marker_name("b%d" % s.id), "Sensor 1")
	world.tick()
	assert_eq(world.triggered_sensors_of("p1").size(), 0)
	var stranger := world.spawn_player(s.center() + Vector2(4, 0), "p2", "Fremder")
	stranger.hidden = true
	var events := []
	for i in 3:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "sensor_triggered":
				events.append(event)
	assert_eq(events.size(), 1, "einmal gemeldet")
	assert_eq(int(events[0]["by"]), stranger.id, "auch versteckte Fremde")
	assert_eq(world.triggered_sensors_of("p1"), ["b%d" % s.id])
	stranger.pos = Vector2(38.5, 20.5)
	world.advance(3.0)
	assert_eq(world.triggered_sensors_of("p1").size(), 1, "hält 5 s nach")
	world.advance(3.0)
	assert_eq(world.triggered_sensors_of("p1").size(), 0)
	var own := world.spawn_player(s.center() + Vector2(1, 0), "p1", "Eigener")
	world.tick()
	assert_eq(world.triggered_sensors_of("p1").size(), 0, "eigene Leute lösen nicht aus")
	assert_eq(own.owner_id, "p1")


func test_rule_reacts_to_sensor_and_goes_there() -> void:
	player.pos = Vector2(27.0, 5.5)
	var s := _sensor(Vector2i(56, 11))  # Sensor bei (28, 5.75)
	player.pos = OPEN
	var pid := "b%d" % s.id
	var rules := data.normalize_rule_list([
		{"if": {"condition": "sensor_triggered", "params": {"sensor": pid}}, "then": {"action": "stay_at", "params": {"place": pid, "radius": 2}}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}},
	], "Test")
	world.logout(player.id, rules, "Wache")
	player.logout_time = -1e9
	for i in 20:
		world.tick()
	assert_eq(player.active_rule_index, 1, "Ruhe: bleibt hier")
	var stranger := world.spawn_player(s.center() + Vector2(3, 0), "p2", "Fremder")
	for i in 20 * 4:
		world.tick()
	assert_eq(player.active_rule_index, 0, "Sensor ausgelöst -> Regel 1")
	assert_lt(player.pos.distance_to(s.center()), 2.5, "geht zum Sensor")
	var lines := SimChronicle.format_all(player)
	var found := false
	for line: String in lines:
		if line.contains("Sensor Sensor 1 ausgelöst, Regel 1: geblieben bei Sensor 1"):
			found = true
	assert_true(found, "Chronik: %s" % [lines])
	stranger.pos = Vector2(38.5, 20.5)
	world.advance(8.0)
	assert_eq(player.active_rule_index, 1, "zurück zu Sonst")


func test_missing_sensor_falls_through() -> void:
	var s := _sensor()
	var pid := "b%d" % s.id
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": pid, "radius": 2}}},
	], "Test")
	world.logout(player.id, rules)
	player.logout_time = -1e9
	world.damage_building(s, 100.0, -1)
	for i in 20:
		world.tick()
	assert_eq(player.active_rule_index, RuleEngine.NO_MATCH)
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Ort existiert nicht mehr"):
			found = true
	assert_true(found)
	assert_false(player.extra_places.has(pid), "Ort entfernt")


func test_trap_is_hidden_to_strangers_damages_and_vanishes() -> void:
	var trap := world.place_building(player, "trap", Vector2i(46, 10), 0)
	assert_not_null(trap)
	assert_true(world.building_visible_to(trap, "p1"))
	assert_false(world.building_visible_to(trap, "p2"), "Fremde sehen die Falle nicht")
	var known := {}
	var nodes := {}
	var state := {}
	var stranger := world.spawn_player(Vector2(26.5, 5.5), "p2", "Fremder")
	world.tick()
	var snap := NetProtocol.snapshot(world, stranger.id, known, nodes, state)
	for row: Array in snap.get("bld", []):
		assert_ne(int(row[0]), trap.id, "Falle nicht im Snapshot des Fremden")
	var own_snap := NetProtocol.snapshot(world, player.id, {}, {}, {})
	var seen := false
	for row: Array in own_snap.get("bld", []):
		if int(row[0]) == trap.id:
			seen = true
	assert_true(seen, "Besitzer sieht sie")
	world.tick()
	assert_eq(player.hp, player.max_hp, "Besitzer löst nicht aus")
	stranger.pos = trap.center()
	var hits := 0
	for i in 3:
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "trap_triggered":
				hits += 1
	assert_eq(hits, 1)
	assert_lt(stranger.hp, stranger.max_hp, "Schaden")
	assert_false(world.map.buildings.has(trap.id), "Falle verbraucht")
	assert_true(SimSensors.is_under_attack(world, stranger), "zählt als Angriff")


func test_sensor_state_in_save_and_snapshot() -> void:
	var s := _sensor()
	s.triggered_until = world.time + 4.0
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_eq(copy.map.buildings[s.id].label, "Sensor 1")
	assert_eq(copy.map.buildings[s.id].triggered_until, s.triggered_until)
	assert_true(copy.get_character(player.id).extra_places.has("b%d" % s.id), "Orte nach dem Laden da")
	var mirror := SimWorld.new(data, 0)
	world.tick()
	var snap := NetProtocol.snapshot(world, player.id, {}, {}, {})
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_eq(mirror.map.buildings[s.id].label, "Sensor 1")
	assert_gt(mirror.map.buildings[s.id].triggered_until, mirror.time, "ausgelöst übertragen")
	var block := NetProtocol.self_block(player)
	assert_true(block["places"].has("b%d" % s.id))
