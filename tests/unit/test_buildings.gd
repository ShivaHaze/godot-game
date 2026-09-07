extends GutTest
## Bauen: Halbkachelraster, Regeln fürs Setzen, Kollision, Türen, Wegsuche, Nahkampf gegen Holz, Verfall, Abriss,
## Spielstand und Snapshot.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 31)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.inventory["wood"] = 20
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


## Setzt eine Holzwand rechts vom Spieler (senkrecht, x = 22, y 5..6 in Kacheln).
func _wall_right() -> SimBuilding:
	var b := world.place_building(player, "wood_wall", Vector2i(44, 10), 0)
	assert_not_null(b, "Wand steht")
	return b


func test_data_and_cells() -> void:
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_eq(data.building_order, ["wood_wall", "wood_door", "anchor", "trade_table", "sensor", "trap", "sign", "spawn_anchor", "depot"] as Array[String])
	assert_eq(SimBuilding.cells_for([1, 2], Vector2i(4, 6), 0), [Vector2i(4, 6), Vector2i(4, 7)] as Array[Vector2i])
	assert_eq(SimBuilding.cells_for([1, 2], Vector2i(4, 6), 1), [Vector2i(4, 6), Vector2i(5, 6)] as Array[Vector2i])
	assert_eq(SimBuilding.half_cell_of(Vector2(20.5, 5.5)), Vector2i(41, 11))


func test_place_rules() -> void:
	assert_eq(world.can_place(player, "turm", Vector2i(44, 10), 0), "unbekanntes Bauteil")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(0, 0), 0), "kein freier Boden", "Rand ist Hindernis")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(60, 46), 0), "zu weit weg")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(41, 11), 0), "jemand steht im Weg")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(44, 10), 0), "")
	player.inventory["wood"] = 3
	assert_eq(world.can_place(player, "wood_wall", Vector2i(44, 10), 0), "zu wenig Holz (4 nötig)")
	player.inventory["wood"] = 20
	var b := _wall_right()
	assert_eq(player.inventory["wood"], 16, "Kosten abgezogen")
	assert_eq(world.can_place(player, "wood_wall", Vector2i(44, 11), 0), "schon bebaut")
	assert_eq(world.map.building_at(Vector2(22.25, 5.75)), b)
	world.logout(player.id, data.roles["guard"]["rules"])
	assert_eq(world.can_place(player, "wood_wall", Vector2i(46, 10), 0), "nur live baubar", "NPCs bauen nie")


func test_wall_blocks_everyone_door_only_strangers() -> void:
	var wall := _wall_right()
	var intent := SimIntent.new()
	intent.move = Vector2.RIGHT
	for i in 20:
		world.set_intent(player.id, intent)
		world.tick()
	assert_lt(player.pos.x, 22.0, "eigene Wand blockiert auch den Besitzer")
	world.remove_building(wall.id)
	var door := world.place_building(player, "wood_door", Vector2i(44, 10), 0)
	assert_not_null(door)
	for i in 20:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gt(player.pos.x, 22.5, "Tür lässt den Besitzer durch")
	var stranger := world.spawn_player(OPEN, "p2", "Fremder")
	for i in 20:
		world.set_intent(stranger.id, intent)
		world.tick()
	assert_lt(stranger.pos.x, 22.0, "Tür blockiert Fremde")


func test_projectile_stops_at_wall() -> void:
	_wall_right()
	var target := world.spawn_player(OPEN + Vector2(5, 0), "p2", "Dahinter")
	target.facing = Vector2.LEFT
	var intent := SimIntent.new()
	intent.aim = Vector2.RIGHT
	intent.shoot = true
	var walls := 0
	for i in 30:
		world.set_intent(player.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "projectile_wall":
				walls += 1
	assert_gt(walls, 0, "Projektil bleibt an der Wand hängen")
	assert_eq(target.hp, target.max_hp, "niemand dahinter getroffen")


func test_melee_breaks_wood_wall_but_npc_never() -> void:
	var b := _wall_right()
	world.craft(player, "club")
	world.set_active_weapon(player, "club")
	player.pos = Vector2(21.4, 5.75)
	var intent := SimIntent.new()
	intent.aim = Vector2.RIGHT
	intent.shoot = true
	var destroyed := false
	for i in 80:
		world.set_intent(player.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == "building_destroyed":
				destroyed = true
	assert_true(destroyed, "drei Keulenschläge reichen für 40 Lebenspunkte")
	assert_false(world.map.buildings.has(b.id))
	# NPC mit Keule schlägt nie Wände ein
	var b2 := _wall_right()
	world.logout(player.id, data.roles["guard"]["rules"])
	player.logout_time = -1e9
	for i in 80:
		world.tick()
	assert_gt(b2.hp, b2.max_hp - 0.01, "Offline kann nicht Nehmen und Verändern (nur Verfall)")


func test_decay_and_demolish_refund() -> void:
	var b := _wall_right()
	world.advance(10 * 3600.0)
	assert_almost_eq(b.hp, 30.0, 0.01, "1 Lebenspunkt je Stunde")
	world.advance(31 * 3600.0)
	assert_false(world.map.buildings.has(b.id), "verfallen")
	var wood := int(player.inventory["wood"])
	var d := world.place_building(player, "wood_door", Vector2i(44, 10), 0)
	assert_eq(int(player.inventory["wood"]), wood - 6)
	var stranger := world.spawn_player(OPEN + Vector2(-1, 0), "p2", "Fremder")
	assert_false(world.can_demolish(stranger, d), "nur der Besitzer")
	assert_true(world.can_demolish(player, d))
	world.remove_building(d.id, player)
	assert_eq(int(player.inventory["wood"]), wood - 3, "50 % zurück")


func test_npc_paths_around_wall_and_wolf_cannot_pass_door() -> void:
	# Wandlinie von y = 3 bis 7 bei x = 25 (Halbzellen x 50, y 6..15): NPC muss oben oder unten herum
	for hy in range(6, 16, 2):
		player.pos = Vector2(26.5, hy * 0.5 + 0.5)
		player.inventory["wood"] = 20
		assert_eq(world.can_place(player, "wood_wall", Vector2i(50, hy), 0), "", "Halbzeile %d" % hy)
		assert_not_null(world.place_building(player, "wood_wall", Vector2i(50, hy), 0))
	player.pos = OPEN
	player.markers.append({"id": "m1", "name": "Ziel", "pos": Vector2(26.5, 5.5)})
	var rules := data.normalize_rule_list([{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "m1", "radius": 1}}}], "Test")
	world.logout(player.id, rules)
	player.logout_time = -1e9
	for i in 20 * 8:
		world.tick()
	assert_lt(player.pos.distance_to(Vector2(26.5, 5.5)), 1.5, "NPC findet den Weg außen herum")
	# Tür: eigener NPC geht durch, Wolf nicht
	var path_owner := world.map.find_path(Vector2i(20, 5), Vector2i(26, 5), 4000, "p1", data)
	var path_wolf := world.map.find_path(Vector2i(20, 5), Vector2i(26, 5), 4000, "wild", data)
	assert_eq(path_owner.size(), path_wolf.size(), "ohne Tür gleich lang")
	world.login(player.id)
	player.pos = Vector2(26.5, 5.75)
	world.remove_building(world.map.building_at_half(Vector2i(50, 10)).id)
	player.inventory["wood"] = 20
	assert_not_null(world.place_building(player, "wood_door", Vector2i(50, 10), 0))
	path_owner = world.map.find_path(Vector2i(20, 5), Vector2i(26, 5), 4000, "p1", data)
	path_wolf = world.map.find_path(Vector2i(20, 5), Vector2i(26, 5), 4000, "wild", data)
	assert_lt(path_owner.size(), path_wolf.size(), "Besitzer nimmt die Tür, der Wolf muss außen herum")


func test_save_and_snapshot_carry_buildings() -> void:
	var b := _wall_right()
	b.hp = 25.0
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var loaded: SimBuilding = copy.map.buildings[b.id]
	assert_eq(loaded.part, "wood_wall")
	assert_eq(loaded.cells, b.cells)
	assert_eq(loaded.hp, 25.0)
	assert_true(copy.map.built_half.has(Vector2i(44, 11)))
	var known := {}
	var nodes := {}
	var state := {}
	world.tick()
	var snap := NetProtocol.snapshot(world, player.id, known, nodes, state)
	assert_eq(snap["bld"].size(), 2, "neues Bauteil und das Markt-Depot im Snapshot")
	var again := NetProtocol.snapshot(world, player.id, known, nodes, state)
	assert_false(again.has("bld"), "unverändert: nicht nochmal")
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_snapshot(mirror, NetProtocol.decode(NetProtocol.encode(snap)))
	assert_true(mirror.map.buildings.has(b.id))
	assert_eq(mirror.map.buildings[b.id].cells, b.cells)
	world.remove_building(b.id)
	var removal := NetProtocol.snapshot(world, player.id, known, nodes, state)
	assert_true(removal.has("bld_rm"))
	NetProtocol.apply_snapshot(mirror, removal)
	assert_false(mirror.map.buildings.has(b.id))
