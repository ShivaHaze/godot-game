extends GutTest
## Sim-Kern: Tick, Bewegung, Hunger, Essen, Sammeln, Uhr.

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 7)
	var id := world.setup_new_game()
	player = world.get_character(id)


func _tick_with(intent: SimIntent, ticks: int) -> void:
	for i in ticks:
		world.set_intent(player.id, intent)
		world.tick()


func _open_area() -> Vector2:
	return Vector2(20.5, 5.5)


func test_setup_spawns_player_and_wolves() -> void:
	assert_eq(player.pos, SimMap.cell_center(data.player_spawns[0]))
	assert_eq(player.control, SimCharacter.Controller.PLAYER)
	assert_eq(world.count_alive_wolves(), mini(data.wolf_spawns.size(), data.bali("wolf.max_alive")))
	assert_eq(player.hunger, data.balf("hunger.start"))
	for rid: String in data.resource_order:
		assert_eq(int(player.inventory[rid]), 0, "leeres Inventar für %s" % rid)


func test_movement_speed_per_second() -> void:
	player.pos = _open_area()
	var intent := SimIntent.new()
	intent.move = Vector2.RIGHT
	_tick_with(intent, data.bali("tick_rate"))
	assert_almost_eq(player.pos.x, _open_area().x + data.balf("character.move_speed"), 0.01)
	assert_eq(player.facing, Vector2.RIGHT, "Blick folgt der Bewegung")


func test_aim_overrides_facing() -> void:
	var intent := SimIntent.new()
	intent.move = Vector2.RIGHT
	intent.aim = Vector2(0, -3)
	_tick_with(intent, 1)
	assert_eq(player.facing, Vector2.UP)


func test_weakened_at_zero_hunger_moves_half_speed() -> void:
	player.pos = _open_area()
	player.hunger = 0.0
	var intent := SimIntent.new()
	intent.move = Vector2.RIGHT
	_tick_with(intent, data.bali("tick_rate"))
	var expected := data.balf("character.move_speed") * data.balf("character.weakened_speed_multiplier")
	assert_almost_eq(player.pos.x, _open_area().x + expected, 0.01)


func test_hunger_decays_live_and_slower_offline() -> void:
	var start := player.hunger
	_tick_with(SimIntent.new(), data.bali("tick_rate") * 10)
	assert_almost_eq(player.hunger, start - 10.0 * data.balf("hunger.decay_per_second_live"), 0.01)
	player.hunger = start
	player.control = SimCharacter.Controller.RULES
	_tick_with(SimIntent.new(), data.bali("tick_rate") * 10)
	assert_almost_eq(player.hunger, start - 10.0 * data.balf("hunger.decay_per_second_offline"), 0.01)
	assert_lt(data.balf("hunger.decay_per_second_offline"), data.balf("hunger.decay_per_second_live"))


func test_hunger_never_below_zero() -> void:
	player.hunger = 0.01
	_tick_with(SimIntent.new(), 5)
	assert_eq(player.hunger, 0.0)


func test_eat_berries_restores_hunger() -> void:
	player.hunger = 40.0
	player.inventory["berries"] = 4
	player.inventory["wood"] = 3
	var intent := SimIntent.new()
	intent.eat = true
	_tick_with(intent, 1)
	var expected := 40.0 + float(data.resources["berries"]["nutrition"]) - data.balf("hunger.decay_per_second_live") * world.tick_dt
	assert_almost_eq(player.hunger, expected, 0.001)
	assert_eq(player.inventory["berries"], 3, "eine Beere verbraucht")
	assert_eq(player.inventory["wood"], 3, "Holz ist nicht essbar")
	var event: Dictionary = world.events[0]
	assert_eq(event["type"], "eat")
	assert_eq(event["before"], 4)
	assert_eq(event["after"], 3)


func test_eat_does_nothing_without_food_or_when_full() -> void:
	player.hunger = 40.0
	var intent := SimIntent.new()
	intent.eat = true
	_tick_with(intent, 1)
	assert_true(world.events.is_empty(), "nichts zu essen")
	player.inventory["berries"] = 2
	player.hunger = data.balf("hunger.max")
	_tick_with(intent, 1)
	assert_eq(player.inventory["berries"], 2, "satt: nichts gegessen")


func test_gather_berries_and_regrow() -> void:
	var bush := map_node_for("berries")
	player.pos = SimMap.cell_center(world.map.nearest_walkable_cell(bush.cell))
	var start_amount := bush.amount
	var intent := SimIntent.new()
	intent.interact = true
	var ticks_per_item := ceili(data.balf("gathering.gather_time") / world.tick_dt)
	_tick_with(intent, ticks_per_item)
	assert_eq(player.inventory["berries"], 1, "ein Stück gesammelt")
	assert_eq(bush.amount, start_amount - 1)
	_tick_with(intent, ticks_per_item * 10)
	assert_eq(bush.amount, 0, "Quelle leer")
	assert_eq(player.inventory["berries"], start_amount)
	var regrow_ticks := ceili(data.balf("gathering.node_regrow_time") / world.tick_dt)
	_tick_with(SimIntent.new(), regrow_ticks + 1)
	assert_eq(bush.amount, 1, "ein Stück nachgewachsen")


func test_gather_stops_when_inventory_full() -> void:
	var bush := map_node_for("berries")
	player.pos = SimMap.cell_center(world.map.nearest_walkable_cell(bush.cell))
	player.inventory["wood"] = data.bali("inventory.capacity")
	var intent := SimIntent.new()
	intent.interact = true
	_tick_with(intent, 40)
	assert_eq(player.inventory["berries"], 0)
	assert_eq(bush.amount, bush.max_amount)


func test_gather_needs_range() -> void:
	player.pos = _open_area()
	var intent := SimIntent.new()
	intent.interact = true
	_tick_with(intent, 40)
	assert_eq(player.inventory_count(), 0)


func test_clock_string() -> void:
	assert_eq(world.clock_string(0.0), "08:00")
	assert_eq(world.clock_string(3600.0 * 8 + 60 * 5), "16:05")
	assert_eq(world.clock_string(3600.0 * 17), "01:00", "Tageswechsel")


func test_marker_placed_at_position() -> void:
	player.pos = _open_area()
	var marker := world.add_marker(player.id)
	assert_eq(marker["id"], "m1")
	assert_eq(marker["name"], "Marker 1")
	assert_eq(player.place_pos("m1"), _open_area())
	assert_eq(player.marker_name("m1"), "Marker 1")
	assert_eq(player.marker_name("here"), "Hier")


func map_node_for(resource: String) -> SimResourceNode:
	for node: SimResourceNode in world.map.nodes.values():
		if node.resource == resource:
			return node
	return null
