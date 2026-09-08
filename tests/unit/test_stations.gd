extends GutTest
## Herstellungsorte: Werkbank, Schmelzofen und Schmiede sind Bauteile (Raidziele). Gegenstände und Verbrauchsgüter mit
## 'needs_building' entstehen nur in Reichweite der Station (auch Reparatur); Offline-Charaktere laufen zur Station in der Leine.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 401)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _raw_data() -> Dictionary:
	var raw := {}
	for key: String in SimData.FILE_NAMES:
		raw[key] = JSON.parse_string(FileAccess.get_file_as_string("res://data".path_join(SimData.FILE_NAMES[key])))
	return raw


func test_data_declares_stations_and_validates_them() -> void:
	assert_eq(data.station_of("bow"), "workbench")
	assert_eq(data.station_of("iron"), "furnace")
	assert_eq(data.station_of("iron_axe"), "forge")
	assert_eq(data.station_of("cooked_meat"), "campfire")
	assert_eq(data.station_of("club"), "", "Keule von Hand")
	assert_eq(data.station_of("cloth"), "", "Stoff von Hand")
	assert_eq(data.station_of("sling"), "", "Schleuder von Hand, damit niemand ohne Waffe festhängt")
	for part: String in ["workbench", "furnace", "forge"]:
		assert_true(bool(data.buildings[part].get("station", false)), part)
	var raw := _raw_data()
	raw["items"]["items"][1]["needs_building"] = "nope"
	var broken := SimData.from_dicts(raw)
	assert_false(broken.is_valid())
	assert_true(String(broken.errors[0]).contains("unbekanntes Bauteil 'nope'"), "%s" % [broken.errors])


func test_crafting_and_repair_need_the_station_in_reach() -> void:
	player.inventory["wood"] = 20
	player.inventory["fibers"] = 4
	player.inventory["stone"] = 4
	assert_eq(world.craft(player, "bow"), "Werkbank nicht in Reichweite")
	assert_eq(world.craft(player, "club"), "", "Keule von Hand")
	var bench := world.spawn_building("workbench", Vector2i(20, 6), "p2")  # fremde Werkbank zählt auch
	assert_not_null(bench)
	assert_eq(world.craft(player, "bow"), "")
	player.inventory["iron_ore"] = 2
	player.inventory["coal"] = 1
	assert_eq(world.craft(player, "iron"), "Schmelzofen nicht in Reichweite")
	world.spawn_building("furnace", Vector2i(19, 6), "p1")
	assert_eq(world.craft(player, "iron"), "")
	player.inventory["iron"] = 3
	assert_eq(world.craft(player, "iron_axe"), "Schmiede nicht in Reichweite")
	world.spawn_building("forge", Vector2i(21, 6), "p1")
	assert_eq(world.craft(player, "iron_axe"), "")
	# Reparatur braucht die Station des Gegenstands
	world.wear(player, "bow", 10.0)
	player.pos = Vector2(10.5, 5.5)
	assert_eq(world.repair_reason(player, "bow"), "Werkbank nicht in Reichweite")
	player.pos = OPEN
	assert_eq(world.repair_reason(player, "bow"), "")
	assert_eq(world.repair(player, "bow"), "")


func test_station_is_built_live_and_is_a_raid_target() -> void:
	player.inventory["wood"] = 8
	player.inventory["stone"] = 4
	var bench := world.place_building(player, "workbench", Vector2i(42, 12), 0)  # Kachel (21, 6)
	assert_not_null(bench, "Werkbank: %s" % world.can_place(player, "workbench", Vector2i(42, 12), 0))
	assert_eq(int(player.inventory["wood"]), 0)
	player.inventory["stone"] = 6
	player.inventory["wood"] = 4
	assert_eq(world.can_place(player, "forge", Vector2i(44, 12), 0), "zu wenig Eisen (3 nötig)", "Schmiede braucht Eisen, also erst den Schmelzofen")
	# Ein Fremder schlägt die Werkbank (Holz) ein
	var raider := world.spawn_player(Vector2(21.5, 7.3), "p2", "Räuber")
	raider.inventory["wood"] = 3
	assert_eq(world.craft(raider, "club"), "")
	world.set_active_weapon(raider, "club")
	raider.facing = Vector2.UP
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.aim = Vector2.UP
	intent.melee = true
	for i in 20 * 4:
		world.set_intent(raider.id, intent)
		world.tick()
	assert_false(world.map.buildings.has(bench.id), "Werkbank eingeschlagen")
	player.inventory["wood"] = 4
	player.inventory["fibers"] = 2
	assert_eq(world.craft(player, "bow"), "Werkbank nicht in Reichweite", "ohne Werkbank keine Stufe 1 mehr")


func test_npc_walks_to_workbench_in_leash_and_crafts() -> void:
	player.inventory["copper"] = 2
	var bench := world.spawn_building("workbench", Vector2i(24, 5), "p1")  # 4 Kacheln östlich, in der Standardleine (6)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "wire"}}},
	], "Test")
	world.logout(player.id, rules, "Schmied")
	player.logout_time = -1e9
	world.advance(20.0)
	assert_eq(int(player.inventory.get("wire", 0)), 4, "2 Kupfer → 4 Draht an der Werkbank: %s" % [player.inventory])
	assert_lt(player.pos.distance_to(bench.center()), 2.0, "steht an der Werkbank: %s" % player.pos)
	var lines := SimChronicle.format_all(player)
	var found := 0
	for line: String in lines:
		if line.contains("hergestellt: Draht (jetzt"):
			found += 1
	assert_eq(found, 2, "Chronik: %s" % [lines])


func test_npc_reports_station_outside_leash() -> void:
	player.inventory["copper"] = 2
	world.spawn_building("workbench", Vector2i(30, 5), "p1")  # 10 Kacheln: außerhalb der Leine
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "wire"}}},
	], "Test")
	world.logout(player.id, rules, "Schmied")
	player.logout_time = -1e9
	world.advance(5.0)
	assert_eq(int(player.inventory.get("wire", 0)), 0)
	assert_lt(player.pos.distance_to(OPEN), 1.0, "bleibt stehen")
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("nicht möglich: Werkbank nicht in der Leine, übersprungen"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
