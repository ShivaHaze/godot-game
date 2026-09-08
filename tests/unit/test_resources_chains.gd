extends GutTest
## Stein, Fasern, Verband (Heilung als Kanalisierung), Steinbeil, NPC-Aktion 'verbinde dich'.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 61)
	world.lod_enabled = false
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = Vector2(38.5, 28.5)
			c.home_pos = c.pos
			c.control = SimCharacter.Controller.NONE


func _heal_intent() -> SimIntent:
	var intent := SimIntent.new()
	intent.heal = true
	return intent


func test_data_has_new_resources_tiles_and_nodes() -> void:
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_eq(data.resource_order, ["wood", "berries", "meat", "hide", "cooked_meat", "stone", "fibers", "cloth", "bandage", "arrow", "copper_ore", "copper", "wire", "iron_ore", "coal", "iron", "sulfur", "powder", "shot", "explosive", "herbs", "antidote", "medicine"] as Array[String])
	assert_true(data.tiles.has("stone_deposit"))
	assert_true(data.tiles.has("fiber_plant"))
	assert_eq(data.craftable_resources(), ["cooked_meat", "cloth", "bandage", "arrow", "copper", "wire", "iron", "powder", "shot", "explosive", "antidote", "medicine"] as Array[String])
	var stone := 0
	var fibers := 0
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource == "stone":
			stone += 1
		if node.resource == "fibers":
			fibers += 1
	assert_gt(stone, 0)
	assert_gt(fibers, 0)
	assert_true(world.map.is_walkable(Vector2i(6, 12)), "Faserpflanze ist begehbar")
	assert_false(world.map.is_walkable(Vector2i(13, 10)), "Steinbruch nicht")
	var gen := SimData.load_from_dir("res://data")
	assert_true(gen.apply_map(MapGen.generate(80, 60, 4)).is_empty())
	assert_true(gen.map_rows[0].length() == 80)
	var joined := "".join(gen.map_rows)
	assert_true(joined.contains("S") and joined.contains("F"), "Generator setzt Stein und Fasern")


func test_gather_fibers_and_craft_bandage() -> void:
	player.pos = SimMap.cell_center(Vector2i(6, 12))
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20 * 3:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gte(int(player.inventory["fibers"]), 3, "Fasern gesammelt (auf der Pflanze stehend)")
	assert_eq(world.craft(player, "bandage"), "zu wenig Stoff (1 nötig)", "Verband braucht die Zwischenstufe Stoff")
	assert_eq(world.craft(player, "cloth"), "")
	assert_eq(world.craft(player, "bandage"), "")
	assert_eq(int(player.inventory["bandage"]), 1)
	assert_true(world.can_use(player, data.action_def("heal_self")), "'verbinde dich' ist immer verfügbar")
	player.inventory["fibers"] = 0
	player.inventory["cloth"] = 0
	assert_eq(world.craft(player, "bandage"), "zu wenig Stoff (1 nötig)")
	assert_eq(world.craft(player, "cloth"), "zu wenig Fasern (2 nötig)")


func test_heal_is_channeled_and_cancelled_by_attack() -> void:
	player.inventory["bandage"] = 2
	player.hp = 10.0
	var ticks := int(3.0 / world.tick_dt)
	for i in ticks - 1:
		world.set_intent(player.id, _heal_intent())
		world.tick()
	assert_eq(player.hp, 10.0, "vor Ablauf der 3 s nichts")
	assert_gt(player.heal_progress, 2.5)
	world.set_intent(player.id, _heal_intent())
	world.tick()
	assert_eq(player.hp, 25.0, "+15 Leben")
	assert_eq(int(player.inventory["bandage"]), 1)
	assert_eq(player.heal_progress, 0.0)
	# Angriff bricht ab
	for i in 20:
		world.set_intent(player.id, _heal_intent())
		world.tick()
	assert_gt(player.heal_progress, 0.5)
	var attack := _heal_intent()
	attack.shoot = true
	attack.aim = Vector2.RIGHT
	world.set_intent(player.id, attack)
	world.tick()
	assert_eq(player.heal_progress, 0.0, "Angreifen bricht die Kanalisierung ab")
	# Laufen ist erlaubt
	var walk := _heal_intent()
	walk.move = Vector2.RIGHT
	for i in ticks + 1:
		world.set_intent(player.id, walk)
		world.tick()
	assert_eq(player.hp, 30.0, "beim Laufen verbunden")
	assert_eq(int(player.inventory["bandage"]), 0)
	world.set_intent(player.id, _heal_intent())
	world.tick()
	assert_eq(player.heal_progress, 0.0, "ohne Verband passiert nichts")


func test_npc_heals_itself_when_rule_says_so() -> void:
	player.inventory["bandage"] = 1
	player.hp = 12.0
	var rules := data.normalize_rule_list([
		{"if": {"condition": "health_below", "params": {"percent": 50}}, "then": {"action": "heal_self"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	], "Test")
	world.logout(player.id, rules)
	player.logout_time = -1e9
	for i in 20 * 4:
		world.tick()
	assert_eq(player.hp, 27.0, "NPC hat sich verbunden")
	assert_eq(int(player.inventory["bandage"]), 0)
	assert_eq(player.active_rule_index, 1, "danach wieder Sonst-Regel")
	var lines := SimChronicle.format_all(player)
	assert_true(lines[1].ends_with("Leben unter 50 %, Regel 1: verbunden"), lines[1])


func test_npc_without_bandage_falls_through() -> void:
	player.hp = 12.0
	var rules := data.normalize_rule_list([
		{"if": {"condition": "health_below", "params": {"percent": 50}}, "then": {"action": "heal_self"}},
		{"if": {"condition": "else"}, "then": {"action": "hide"}},
	], "Test")
	world.logout(player.id, rules)
	player.logout_time = -1e9
	for i in 20:
		world.tick()
	assert_eq(player.active_rule_index, 1)
	var found := false
	for line: String in SimChronicle.format_all(player):
		if line.contains("nicht möglich: kein passendes Heilmittel"):
			found = true
	assert_true(found)


func test_stone_axe_and_stone_gathering() -> void:
	player.pos = SimMap.cell_center(world.map.nearest_walkable_cell(Vector2i(13, 10)))
	var intent := SimIntent.new()
	intent.interact = true
	for i in 20 * 3:
		world.set_intent(player.id, intent)
		world.tick()
	assert_gte(int(player.inventory["stone"]), 2, "Stein gesammelt")
	player.inventory["wood"] = 2
	world.spawn_building("workbench", SimMap.cell_of(player.pos) + Vector2i(0, 1), "p1")
	assert_eq(world.craft(player, "stone_axe"), "")
	world.set_active_weapon(player, "stone_axe")
	assert_eq(player.melee_damage, 20.0)
	assert_gt(int(data.items["stone_axe"]["damage"]), int(data.items["club"]["damage"]), "Stufe 0 schlägt Keule")
