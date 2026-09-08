extends GutTest
## Verschleiß: jede Nutzung kostet Haltbarkeit, bei 0 zerbricht der Gegenstand; Reparatur nie wieder 100 %.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 121)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	player.facing = Vector2.RIGHT
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE
	world.spatial.rebuild(world.characters)


func test_shots_wear_sling_until_it_breaks() -> void:
	var max_uses := float(data.items["sling"]["durability"])
	assert_eq(SimCrafting.durability_left(world, player, "sling"), max_uses, "Start voll")
	var intent := SimIntent.new()
	intent.shoot = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(SimCrafting.durability_left(world, player, "sling"), max_uses - 1.0, "ein Schuss = 1")
	SimCrafting.wear(world, player, "sling", max_uses - 2.0)
	player.fire_cooldown = 0.0
	world.set_intent(player.id, intent)
	world.tick()
	assert_false(player.items.has("sling"), "zerbrochen")
	assert_eq(player.active_weapon, "", "keine Waffe mehr")
	var broken := false
	for event: Dictionary in world.events:
		if event.get("type") == "item_broken" and event.get("item") == "sling":
			broken = true
	assert_true(broken)


func test_melee_and_armor_wear() -> void:
	player.inventory["wood"] = 20
	world.spawn_building("workbench", Vector2i(20, 6), "p1")  # Station in Reichweite
	assert_eq(SimCrafting.craft(world, player, "club"), "")
	assert_eq(SimCrafting.craft(world, player, "wood_armor"), "")
	SimCrafting.set_active_weapon(world, player, "club")
	var victim := world.spawn_player(OPEN + Vector2(0.8, 0), "p2", "Opfer")
	victim.inventory["wood"] = 6
	assert_eq(SimCrafting.craft(world, victim, "wood_armor"), "")
	assert_eq(SimCrafting.equip_armor(world, victim, "wood_armor"), "")
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.melee = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(SimCrafting.durability_left(world, player, "club"), float(data.items["club"]["durability"]) - 1.0, "Schlag nutzt die Keule ab")
	assert_eq(SimCrafting.durability_left(world, victim, "wood_armor"), float(data.items["wood_armor"]["durability"]) - 1.0, "Treffer nutzt die Rüstung des Opfers ab")
	assert_eq(SimCrafting.durability_left(world, player, "wood_armor"), float(data.items["wood_armor"]["durability"]), "eigene Rüstung unberührt")
	SimCrafting.wear(world, victim, "wood_armor", 100.0)
	assert_false(victim.items.has("wood_armor"))
	assert_eq(victim.armor, data.balf("character.armor"), "ohne Rüstung nur der Grundwert")


func test_repair_costs_half_and_lowers_maximum_until_unrepairable() -> void:
	player.inventory["wood"] = 20
	assert_eq(SimCrafting.craft(world, player, "club"), "")
	assert_eq(SimCrafting.repair_reason(world, player, "club"), "nicht abgenutzt")
	SimCrafting.wear(world, player, "club", 30.0)
	var cost := SimCrafting.repair_cost(world, "club")
	assert_eq(int(cost["wood"]), 2, "3 Holz × 0,5 aufgerundet")
	var wood_before := int(player.inventory["wood"])
	assert_eq(SimCrafting.repair(world, player, "club"), "")
	assert_eq(int(player.inventory["wood"]), wood_before - 2)
	var full := float(data.items["club"]["durability"])
	var expected_max := full - full * data.balf("wear.repair_max_loss")
	assert_almost_eq(SimCrafting.durability_max(world, player, "club"), expected_max, 0.001, "Maximum sinkt")
	assert_almost_eq(SimCrafting.durability_left(world, player, "club"), expected_max, 0.001, "voll bis zum neuen Maximum")
	var repairs := 1
	while true:
		SimCrafting.wear(world, player, "club", 1.0)
		player.inventory["wood"] = 20
		var reason := SimCrafting.repair(world, player, "club")
		if not reason.is_empty():
			assert_eq(reason, "zu abgenutzt, nicht mehr reparierbar")
			break
		repairs += 1
		assert_lt(repairs, 10, "irgendwann ist Schluss")
	assert_eq(repairs, 4, "bei 20 % Verlust je Reparatur: 4 Reparaturen")
	world.logout(player.id, data.roles["hide"]["rules"])
	assert_eq(SimCrafting.repair_reason(world, player, "club"), "nur live")


func test_durability_in_save_self_block_and_loot() -> void:
	SimCrafting.wear(world, player, "sling", 50.0)
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	assert_eq(SimCrafting.durability_left(copy, copy.get_character(player.id), "sling"), SimCrafting.durability_left(world, player, "sling"), "Spielstand")
	var mirror := SimWorld.new(data, 0)
	NetProtocol.apply_self(mirror, player.id, NetProtocol.decode(NetProtocol.encode(NetProtocol.self_block(player))))
	assert_eq(SimCrafting.durability_left(mirror, mirror.get_character(player.id), "sling"), SimCrafting.durability_left(world, player, "sling"), "Selbstblock")
	# Beute: Haltbarkeit wandert mit dem Gegenstand
	var victim := world.spawn_player(OPEN + Vector2(0.8, 0), "p2", "Opfer")
	victim.inventory["wood"] = 6
	assert_eq(SimCrafting.craft(world, victim, "club"), "")
	SimCrafting.wear(world, victim, "club", 10.0)
	SimCombat.apply_damage(world, victim, 1000.0, Vector2.RIGHT, player.id)
	assert_true(victim.dead)
	world.spatial.rebuild(world.characters)
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20 * 3:
		world.set_intent(player.id, intent)
		world.tick()
	assert_true(player.items.has("club"), "Keule geplündert")
	assert_eq(SimCrafting.durability_left(world, player, "club"), float(data.items["club"]["durability"]) - 10.0, "abgenutzt wie vorher")
	assert_false(victim.durability.has("club"))


func test_npc_logs_broken_weapon() -> void:
	player.inventory["wood"] = 20
	assert_eq(SimCrafting.craft(world, player, "club"), "")
	SimCrafting.set_active_weapon(world, player, "club")
	world.logout(player.id, data.roles["guard"]["rules"], "Wache")
	SimCrafting.wear(world, player, "club", 100.0)
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("Keule zerbrochen"):
			found = true
	assert_true(found, "Chronik: %s" % [SimChronicle.format_all(player)])
	assert_eq(player.active_weapon, "sling", "fällt auf die Schleuder zurück")
