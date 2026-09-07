extends GutTest
## Ausrüstung: Werkbank, Waffenwechsel, Nahkampf, Rüstung, Plündern von Ausrüstung, NPC nutzt Keule.

const OPEN: Vector2 = Vector2(20.5, 5.5)
const PARKING: Vector2 = Vector2(38.5, 28.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 13)
	world.lod_enabled = false  # Feinsimulation für nachvollziehbare Zeiten
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = PARKING
			c.home_pos = PARKING
			c.ai_target_pos = PARKING
			c.control = SimCharacter.Controller.NONE


func _wolf() -> SimCharacter:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			return c
	return null


func _tick(ticks: int, intent: SimIntent = null, collect_type: String = "") -> Array:
	var collected := []
	for i in ticks:
		if intent != null:
			world.set_intent(player.id, intent)
		world.tick()
		for event: Dictionary in world.events:
			if event.get("type") == collect_type:
				collected.append(event)
	return collected


func test_items_data_loaded() -> void:
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_eq(data.item_order, ["sling", "bow", "club", "stone_axe", "copper_spear", "cloth_armor", "wood_armor"] as Array[String])
	assert_true(player.items.has("sling"), "Startausrüstung")
	assert_eq(player.active_weapon, "sling")
	assert_eq(player.armor, data.balf("character.armor"))


func test_craft_needs_resources_and_updates_equipment() -> void:
	assert_eq(world.craft(player, "club"), "zu wenig Holz (3 nötig)")
	player.inventory["wood"] = 10
	assert_eq(world.craft(player, "club"), "")
	assert_eq(player.inventory["wood"], 7)
	assert_true(player.items.has("club"))
	assert_eq(world.craft(player, "club"), "schon vorhanden")
	assert_eq(world.craft(player, "wood_armor"), "")
	assert_eq(player.inventory["wood"], 1)
	assert_eq(player.armor, data.balf("character.armor") + 3.0, "beste Rüstung zählt")
	assert_eq(world.craft(player, "unbekannt"), "unbekannter Gegenstand")


func test_switch_weapon_and_melee_hit() -> void:
	player.inventory["wood"] = 3
	world.craft(player, "club")
	assert_eq(player.active_weapon, "sling", "Bauen wechselt nicht automatisch")
	world.set_active_weapon(player, "club")
	assert_eq(player.active_weapon, "club")
	assert_eq(player.melee_damage, 16.0)
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(0.8, 0)
	wolf.facing = Vector2.LEFT
	var intent := SimIntent.new()
	intent.aim = Vector2.RIGHT
	intent.shoot = true
	var hits := _tick(3, intent, "hit")
	assert_eq(hits.size(), 1, "ein Schlag (Cooldown)")
	assert_eq(hits[0]["damage"], 16.0)
	assert_eq(world.projectiles.size(), 0, "kein Projektil im Nahkampf")
	world.set_active_weapon(player, "sling")
	assert_eq(player.melee_damage, 0.0)
	hits = _tick(1, intent, "shoot")
	assert_eq(hits.size(), 1, "Schleuder schießt wieder")


func test_armor_reduces_projectile_damage() -> void:
	var other := world.spawn_player(OPEN + Vector2(3, 0), "p2", "Fremder")
	other.facing = Vector2.LEFT
	other.inventory["wood"] = 6
	world.craft(other, "wood_armor")
	var intent := SimIntent.new()
	intent.aim = Vector2.RIGHT
	intent.shoot = true
	var hits := _tick(20, intent, "hit")
	assert_gt(hits.size(), 0)
	assert_eq(hits[0]["damage"], 7.0, "10 − 3 Rüstung")


func test_loot_transfers_items() -> void:
	var other := world.spawn_player(OPEN + Vector2(1, 0), "p2", "Fremder")
	other.inventory["wood"] = 9
	world.craft(other, "club")
	world.craft(other, "wood_armor")
	other.dead = true
	var intent := SimIntent.new()
	intent.interact = true
	var loots := _tick(1, intent, "loot")
	assert_eq(loots.size(), 1)
	assert_true(player.items.has("club"))
	assert_true(player.items.has("wood_armor"))
	assert_eq(player.armor, data.balf("character.armor") + 3.0)
	assert_false(other.items.has("club"))
	assert_eq(other.items.size(), 1, "Startwaffe bleibt bei der Leiche, weil der Plünderer sie schon hat")


func test_npc_uses_club_against_adjacent_wolf() -> void:
	player.inventory["wood"] = 3
	world.craft(player, "club")
	var rules := data.normalize_rule_list([
		{"if": {"condition": "under_attack"}, "then": {"action": "fight_back"}},
		{"if": {"condition": "else"}, "then": {"action": "stay_at", "params": {"place": "here", "radius": 3}}},
	], "Test")
	world.logout(player.id, rules)
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(0.8, 0)
	wolf.facing = Vector2.RIGHT
	world.apply_damage(player, 1.0, Vector2.LEFT, wolf.id)
	var hits := _tick(20, null, "hit")
	var club_hits := 0
	for hit: Dictionary in hits:
		if hit["attacker"] == player.id and hit["damage"] >= 16.0:
			club_hits += 1
	assert_gt(club_hits, 0, "NPC schlägt mit der Keule zu (von hinten sogar doppelt)")
	assert_eq(player.active_weapon, "club")


func test_save_keeps_items() -> void:
	player.inventory["wood"] = 9
	world.craft(player, "club")
	world.craft(player, "wood_armor")
	world.set_active_weapon(player, "club")
	var copy := SimSave.world_from_dict(data, SimSave.world_to_dict(world))
	var loaded: SimCharacter = copy.get_character(player.id)
	assert_eq(loaded.items, player.items)
	assert_eq(loaded.active_weapon, "club")
	assert_eq(loaded.armor, player.armor)
	assert_eq(loaded.melee_damage, 16.0)
