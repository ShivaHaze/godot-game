extends GutTest
## Kette Fasern → Stoff → Verband/Stoffrüstung und die NPC-Aktion "stelle {Erzeugnis} her".

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 141)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_chain_fibers_cloth_bandage_and_armor() -> void:
	assert_eq(data.craftable_resources(), ["cloth", "bandage"] as Array[String])
	player.inventory["fibers"] = 2
	assert_eq(world.craft(player, "bandage"), "zu wenig Stoff (1 nötig)")
	assert_eq(world.craft(player, "cloth"), "")
	assert_eq(int(player.inventory["cloth"]), 1)
	assert_eq(int(player.inventory["fibers"]), 0)
	assert_eq(world.craft(player, "bandage"), "")
	assert_eq(int(player.inventory["bandage"]), 1)
	assert_true(world.can_use(player, data.action_def("craft")), "erstes Herstellen schaltet 'stelle her' frei")
	player.inventory["cloth"] = 4
	assert_eq(world.craft(player, "cloth_armor"), "")
	assert_eq(player.armor, data.balf("character.armor") + 2.0, "Stoffrüstung zählt")
	player.inventory["wood"] = 6
	assert_eq(world.craft(player, "wood_armor"), "")
	assert_eq(player.armor, data.balf("character.armor") + 3.0, "beste Rüstung zählt")


func test_npc_crafts_cloth_then_bandages_and_logs() -> void:
	player.inventory["fibers"] = 6
	world.unlock("p1", "crafted_consumable", player)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "bandage"}}},
	], "Test")
	assert_true(data.errors.is_empty(), "Regel gültig: %s" % [data.errors])
	world.logout(player.id, rules, "Näher")
	player.logout_time = -1e9
	for i in 20 * 3:
		world.tick()
	assert_eq(int(player.inventory.get("bandage", 0)), 0, "ohne Stoff kein Verband")
	assert_eq(player.active_rule_index, RuleEngine.NO_MATCH)
	var lines := SimChronicle.format_all(player)
	var reason_seen := false
	for line: String in lines:
		if line.contains("zu wenig Stoff (1 nötig)"):
			reason_seen = true
	assert_true(reason_seen, "Grund in der Chronik: %s" % [lines])
	# Zwei Stufen als zwei Regeln: erst Stoff, dann Verband
	world.login(player.id)
	player.inventory["fibers"] = 6
	player.inventory["cloth"] = 0
	rules = data.normalize_rule_list([
		{"if": {"condition": "inventory_state", "params": {"state": "full"}}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 2}}},
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "cloth"}}},
	], "Test")
	world.logout(player.id, rules, "Näher")
	player.logout_time = -1e9
	for i in 20 * 3:
		world.tick()
	assert_eq(int(player.inventory["cloth"]), 3, "6 Fasern → 3 Stoff")
	assert_eq(int(player.inventory["fibers"]), 0)
	var crafted := 0
	for line: String in SimChronicle.format_all(player):
		if line.contains("hergestellt: Stoff (jetzt"):
			crafted += 1
	assert_eq(crafted, 3, "jedes Stück protokolliert: %s" % [SimChronicle.format_all(player)])


func test_product_param_validation_and_display() -> void:
	var before := data.errors.size()
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "craft", "params": {"product": "wood"}}},
	], "Test")
	assert_gt(data.errors.size(), before, "Holz ist kein Erzeugnis")
	assert_eq(String(rules[0]["then"]["params"]["product"]), "cloth", "auf das erste Erzeugnis zurückgesetzt")
	data.errors.resize(before)
	var def := data.action_def("craft")
	assert_eq(data.display_value(def["params"][0], "bandage"), "Verband")
	assert_eq(data.format_template(String(def["label"]), def["params"], rules[0]["then"]["params"]), "stelle Stoff her")
