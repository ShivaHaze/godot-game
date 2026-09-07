extends GutTest
## Sensorwerte aus dem Weltzustand und Chronik-Formatierung.

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 3)
	player = world.get_character(world.setup_new_game())
	# Wölfe weit weg, damit Tests die Distanz selbst bestimmen
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)


func test_facts_have_all_documented_keys() -> void:
	var facts := SimSensors.facts_for(world, player)
	for fact_name: String in ["always", "health_percent", "is_hungry", "is_under_attack", "nearest_stranger_distance", "inventory_state"]:
		assert_true(facts.has(fact_name), "Sensorwert %s fehlt" % fact_name)
	# Jede Bedingung aus den Daten muss auf einen vorhandenen Sensorwert zeigen
	for id: String in data.condition_order:
		assert_true(facts.has(data.conditions[id]["check"]["fact"]), "Bedingung %s nutzt unbekannten Sensorwert" % id)


func test_hungry_threshold() -> void:
	player.hunger = data.balf("hunger.hungry_threshold")
	assert_false(SimSensors.facts_for(world, player)["is_hungry"], "genau an der Grenze: nicht hungrig")
	player.hunger -= 0.1
	assert_true(SimSensors.facts_for(world, player)["is_hungry"])


func test_under_attack_window() -> void:
	assert_false(SimSensors.is_under_attack(world, player), "nie getroffen")
	world.time = 100.0
	player.last_damage_time = 100.0
	assert_true(SimSensors.is_under_attack(world, player))
	world.time = 100.0 + data.balf("combat.under_attack_window") + 0.01
	assert_false(SimSensors.is_under_attack(world, player), "Fenster abgelaufen")


func test_stranger_distance_ignores_own_dead_and_hidden() -> void:
	player.pos = Vector2(20.5, 5.5)
	var wolf: SimCharacter = null
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			wolf = c
	wolf.pos = player.pos + Vector2(3, 0)
	assert_almost_eq(SimSensors.nearest_stranger_distance(world, player), 3.0, 0.001, "Wolf zählt als Fremder")
	var friend := world.spawn_player(player.pos + Vector2(1, 0), player.owner_id, "Eigener")
	assert_almost_eq(SimSensors.nearest_stranger_distance(world, player), 3.0, 0.001, "gleicher Besitzer ist kein Fremder")
	var other := world.spawn_player(player.pos + Vector2(0, 2), "p2", "Fremder")
	assert_almost_eq(SimSensors.nearest_stranger_distance(world, player), 2.0, 0.001, "anderer Spieler ist Fremder")
	other.hidden = true
	assert_almost_eq(SimSensors.nearest_stranger_distance(world, player), 3.0, 0.001, "versteckt = unsichtbar")
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.dead = true
	other.hidden = false
	other.dead = true
	assert_gt(SimSensors.nearest_stranger_distance(world, player), 100.0, "nur Tote übrig: kein Fremder")
	assert_eq(friend.owner_id, player.owner_id)


func test_inventory_state() -> void:
	assert_eq(SimSensors.inventory_state(player, 20), "empty")
	player.inventory["wood"] = 5
	assert_eq(SimSensors.inventory_state(player, 20), "partial")
	player.inventory["berries"] = 15
	assert_eq(SimSensors.inventory_state(player, 20), "full")


func test_chronicle_entry_format() -> void:
	world.time = 5 * 60.0 + 2
	var rule: Dictionary = data.roles["guard"]["rules"][2]  # hungrig -> iss
	SimChronicle.log_rule(world, player, 0, rule, "Beeren 4→3")
	assert_eq(player.chronicle.size(), 1)
	assert_eq(SimChronicle.format_entry(player.chronicle[0]), "08:05 – hungrig, Regel 1: gegessen (Beeren 4→3)")
	assert_eq(world.events[0]["type"], "chronicle")


func test_chronicle_resolves_places_and_params() -> void:
	world.time = 3 * 3600.0 + 14 * 60.0
	player.markers.append({"id": "m1", "name": "Lager", "pos": Vector2(5, 5)})
	var flee := data.normalize_rule({"if": {"condition": "under_attack"}, "then": {"action": "flee_to", "params": {"place": "m1", "radius": 3}}}, "Test")
	SimChronicle.log_rule(world, player, 1, flee)
	var low := data.normalize_rule({"if": {"condition": "health_below", "params": {"percent": 30}}, "then": {"action": "gather", "params": {"resource": "wood", "place": "here"}}}, "Test")
	SimChronicle.log_rule(world, player, 0, low)
	var lines := SimChronicle.format_all(player)
	assert_eq(lines[0], "11:14 – angegriffen, Regel 2: geflohen zu Lager")
	assert_eq(lines[1], "11:14 – Leben unter 30 %, Regel 1: gesammelt: Holz um Hier")
