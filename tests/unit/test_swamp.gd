extends GutTest
## Sumpf vergiftet, Kräuter wachsen dort; Gegenmittel und Medizin aus Kräutern; Bedingung "vergiftet"; H nimmt das passende Mittel.

const OPEN: Vector2 = Vector2(20.5, 5.5)
const SWAMP: Vector2 = Vector2(30.5, 8.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 221)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func test_swamp_poisons_and_wears_off_after_leaving() -> void:
	assert_eq(world.map.zone(Vector2i(30, 8)), "swamp")
	assert_eq(world.map.node_at(Vector2i(31, 9)).resource, "herbs")
	player.pos = SWAMP
	world.advance(4.0)
	assert_true(world.has_effect(player, "poison"), "im Sumpf vergiftet")
	assert_almost_eq(player.hp, player.max_hp - 4.0 * data.balf("effects.poison.damage_per_second"), 0.2, "Gift zieht Leben")
	player.pos = OPEN
	world.advance(data.balf("effects.poison.duration") - 1.0)
	assert_true(world.has_effect(player, "poison"), "wirkt noch nach")
	world.advance(2.0)
	assert_false(world.has_effect(player, "poison"), "abgeklungen")
	player.inventory["wood"] = 10
	player.pos = Vector2(29.5, 8.5)
	assert_eq(world.can_place(player, "wood_wall", Vector2i(60, 16), 0), "im Sumpf versinkt jedes Bauteil")


func test_antidote_and_medicine_and_heal_choice() -> void:
	player.inventory["herbs"] = 5
	player.inventory["cloth"] = 1
	assert_false(world.can_use(player, data.condition_def("poisoned")))
	assert_eq(world.craft(player, "antidote"), "")
	assert_true(world.can_use(player, data.condition_def("poisoned")), "Gegenmittel schaltet 'vergiftet' frei")
	assert_eq(world.craft(player, "medicine"), "")
	player.inventory["bandage"] = 1
	# Vergiftet und verletzt: H nimmt zuerst das Gegenmittel
	world.apply_effect(player, "poison", -1)
	player.hp = 10.0
	assert_eq(world.heal_item_of(player), "antidote")
	var intent := SimIntent.new()
	intent.heal = true
	for i in 20 * 2 + 1:
		world.set_intent(player.id, intent)
		world.tick()
	assert_false(world.has_effect(player, "poison"), "kuriert")
	assert_eq(int(player.inventory["antidote"]), 0)
	# Nur verletzt: das stärkste Mittel (Medizin +30) vor dem Verband
	assert_eq(world.heal_item_of(player), "medicine")
	var before := player.hp
	for i in 20 * 2 + 1:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gt(player.hp, before + 15.0, "Medizin heilt stark")
	assert_eq(int(player.inventory["medicine"]), 0)
	player.hp = player.max_hp
	assert_eq(world.heal_item_of(player), "", "gesund: nichts nötig")
	player.inventory["bandage"] = 0
	world.apply_effect(player, "poison", -1)
	assert_eq(world.heal_item_of(player), "", "kein Gegenmittel mehr")


func test_npc_rule_poisoned_uses_antidote_and_gathers_herbs() -> void:
	player.inventory["antidote"] = 1
	world.unlock("p1", "owned_antidote", player)
	player.pos = Vector2(30.5, 9.5)  # neben den Kräutern (31, 9)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "poisoned"}, "then": {"action": "heal_self"}},
		{"if": {"condition": "else"}, "then": {"action": "gather", "params": {"resource": "herbs", "place": "here", "radius": 3}}},
	], "Test")
	world.logout(player.id, rules, "Kräutersammler")
	player.logout_time = -1e9
	for i in 20 * 8:
		world.tick()
	var lines := SimChronicle.format_all(player)
	var cured := false
	var gathered := false
	for line: String in lines:
		if line.contains("vergiftet, Regel 1: verbunden"):
			cured = true
		if line.contains("gesammelt: Kräuter"):
			gathered = true
	assert_true(cured, "Chronik: %s" % [lines])
	assert_true(gathered, "Kräuter offline sammelbar: %s" % [lines])
	assert_gte(int(player.inventory.get("herbs", 0)), 1)


func test_generator_has_swamps_with_herbs() -> void:
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(120, 90, 7)).is_empty())
	var big := SimWorld.new(gen, 1)
	var swamp := 0
	for y in big.map.height:
		for x in big.map.width:
			if big.map.zone(Vector2i(x, y)) == "swamp":
				swamp += 1
	var herbs := 0
	for node: SimResourceNode in big.map.nodes.values():
		if node.resource == "herbs":
			herbs += 1
	assert_gt(swamp, 20, "Sumpfkacheln")
	assert_gt(herbs, 2, "Kräuter")
