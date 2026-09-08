extends GutTest
## Bogen und Pfeile: Munition als Senke; ohne Pfeile kein Schuss, NPCs greifen zur nächsten Waffe.

const OPEN: Vector2 = Vector2(20.5, 5.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 151)
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


func _bow() -> void:
	player.inventory["wood"] = 10
	player.inventory["fibers"] = 2
	player.inventory["stone"] = 2
	world.spawn_building("workbench", Vector2i(20, 6), "p1")  # Station in Reichweite
	assert_eq(SimCrafting.craft(world, player, "bow"), "")
	assert_true(SimCrafting.set_active_weapon(world, player, "bow"))


func test_arrows_are_crafted_in_batches_and_consumed_per_shot() -> void:
	_bow()
	assert_eq(SimCrafting.craft(world, player, "arrow"), "")
	assert_eq(int(player.inventory["arrow"]), 4, "4 Pfeile je Herstellung")
	assert_eq(int(player.inventory["wood"]), 10 - 4 - 1)
	var intent := SimIntent.new()
	intent.shoot = true
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(world.projectiles.size(), 1)
	assert_eq(int(player.inventory["arrow"]), 3, "ein Pfeil je Schuss")
	assert_eq(world.projectiles[0].damage, 14.0, "Bogenschaden")
	player.inventory["arrow"] = 0
	player.fire_cooldown = 0.0
	world.projectiles.clear()
	world.set_intent(player.id, intent)
	world.tick()
	assert_eq(world.projectiles.size(), 0, "ohne Pfeile kein Schuss")
	var no_ammo := false
	for event: Dictionary in world.events:
		if event.get("type") == "no_ammo":
			no_ammo = true
	assert_true(no_ammo)
	assert_eq(SimCrafting.durability_left(world, player, "bow"), float(data.items["bow"]["durability"]) - 1.0, "nur der echte Schuss nutzt ab")
	# Die Schleuder braucht keine Munition
	assert_true(SimCrafting.has_ammo(world, player, "sling"))
	assert_false(SimCrafting.has_ammo(world, player, "bow"))


func test_npc_prefers_bow_with_arrows_and_falls_back_without() -> void:
	_bow()
	player.inventory["arrow"] = 2
	var wolf := world.spawn_wolf(OPEN + Vector2(5, 0))
	wolf.control = SimCharacter.Controller.NONE
	wolf.max_hp = 500.0  # soll den Test überleben (ein Pfeil tötet sonst einen Wolf)
	wolf.hp = wolf.max_hp
	world.spatial.rebuild(world.characters)
	var rules := data.normalize_rule_list([
		{"if": {"condition": "else"}, "then": {"action": "fight_back"}},
	], "Test")
	world.logout(player.id, rules, "Wache")
	player.logout_time = -1e9
	player.last_damage_time = world.time  # gilt als angegriffen
	world.tick()
	assert_eq(player.active_weapon, "bow", "Bogen mit Pfeilen ist die stärkste Fernwaffe")
	for i in 20 * 15:
		player.last_damage_time = world.time
		wolf.hp = wolf.max_hp
		world.tick()
		if int(player.inventory.get("arrow", 0)) == 0 and player.active_weapon != "bow":
			break
	assert_eq(int(player.inventory.get("arrow", 0)), 0, "Pfeile verschossen")
	assert_eq(player.active_weapon, "sling", "ohne Pfeile zurück zur Schleuder")


func test_inventory_capacity_respects_yield() -> void:
	player.inventory["wood"] = 1
	player.inventory["stone"] = 1
	player.inventory["berries"] = data.bali("inventory.capacity") - 3
	assert_eq(SimCrafting.craft(world, player, "arrow"), "Inventar voll", "4 Pfeile passen nicht mehr")
	assert_eq(SimCrafting.craft_reason(world, player, "arrow"), "Inventar voll")
	player.inventory["berries"] = data.bali("inventory.capacity") - 4
	assert_eq(SimCrafting.craft(world, player, "arrow"), "")
