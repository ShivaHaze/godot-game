extends GutTest
## Marker verwalten: umbenennen, löschen; Regeln, die einen gelöschten Marker nutzen, fallen auf "Hier" zurück.

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 3)
	world.lod_enabled = false  # Feinsimulation für nachvollziehbare Zeiten
	player = world.get_character(world.setup_new_game())


func test_rename_marker() -> void:
	world.add_marker(player.id)
	assert_true(world.rename_marker(player.id, "m1", "Lager"))
	assert_eq(player.marker_name("m1"), "Lager")
	assert_false(world.rename_marker(player.id, "m9", "Nix"), "unbekannter Marker")
	assert_false(world.rename_marker(player.id, "m1", "   "), "leerer Name")
	assert_eq(player.marker_name("m1"), "Lager")


func test_remove_marker_falls_back_to_here_in_rules() -> void:
	world.add_marker(player.id)
	player.pos += Vector2(5, 0)
	world.add_marker(player.id)
	player.rules = data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "flee_to", "params": {"place": "m1", "radius": 2}}},
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "wood", "place": "m2", "radius": 4}}},
	], "Test")
	assert_true(world.remove_marker(player.id, "m1"))
	assert_eq(player.markers.size(), 1)
	assert_eq(player.markers[0]["id"], "m2", "übriger Marker behält seine Kennung")
	assert_eq(player.rules[0]["then"]["params"]["place"], "here", "Regel fällt auf Hier zurück")
	assert_eq(player.rules[1]["then"]["params"]["place"], "m2", "andere Regel unverändert")
	assert_false(world.remove_marker(player.id, "m1"), "schon weg")
	var third := world.add_marker(player.id)
	assert_eq(third["id"], "m3", "Kennungen werden nicht wiederverwendet")
	assert_eq(third["name"], "Marker 3")
