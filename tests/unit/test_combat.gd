extends GutTest
## Kampf: Richtungstreffer, Rüstung, Projektile, Nahkampf, Tod, Plündern, Wolf-KI, Determinismus.

const OPEN: Vector2 = Vector2(20.5, 5.5)
const PARKING: Vector2 = Vector2(38.5, 28.5)

var data: SimData
var world: SimWorld
var player: SimCharacter


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	world = SimWorld.new(data, 11)
	player = world.get_character(world.setup_new_game())
	player.pos = OPEN
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.pos = PARKING
			c.home_pos = PARKING
			c.ai_target_pos = PARKING


func _wolf() -> SimCharacter:
	var ids: Array = world.characters.keys()
	ids.sort()
	for id: int in ids:
		var c: SimCharacter = world.characters[id]
		if c.kind == SimCharacter.Kind.WOLF:
			return c
	return null


## Tickt mit derselben Absicht und sammelt Ereignisse eines Typs.
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


func _shoot_intent(direction: Vector2) -> SimIntent:
	var intent := SimIntent.new()
	intent.aim = direction
	intent.shoot = true
	return intent


func test_hit_side_front_side_back() -> void:
	var f := 120.0
	var b := 90.0
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, Vector2.LEFT, f, b), SimCombat.HitSide.FRONT, "Treffer fliegt nach links, Angreifer steht vor dem Opfer")
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, Vector2.RIGHT, f, b), SimCombat.HitSide.BACK, "Angreifer steht hinter dem Opfer")
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, Vector2.DOWN, f, b), SimCombat.HitSide.SIDE)
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, -Vector2.RIGHT.rotated(deg_to_rad(59)), f, b), SimCombat.HitSide.FRONT, "59° noch vorn")
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, -Vector2.RIGHT.rotated(deg_to_rad(61)), f, b), SimCombat.HitSide.SIDE, "61° seitlich")
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, -Vector2.RIGHT.rotated(deg_to_rad(134)), f, b), SimCombat.HitSide.SIDE, "134° noch seitlich")
	assert_eq(SimCombat.hit_side(Vector2.RIGHT, -Vector2.RIGHT.rotated(deg_to_rad(136)), f, b), SimCombat.HitSide.BACK, "136° hinten")


func test_damage_multipliers_and_flat_armor() -> void:
	assert_eq(SimCombat.damage(10.0, 3.0, SimCombat.HitSide.FRONT, data), 7.0, "flacher Abzug")
	assert_eq(SimCombat.damage(10.0, 3.0, SimCombat.HitSide.SIDE, data), 12.0, "×1,5 − 3")
	assert_eq(SimCombat.damage(10.0, 3.0, SimCombat.HitSide.BACK, data), 18.5, "×2 − halbe Rüstung")
	assert_eq(SimCombat.damage(10.0, 20.0, SimCombat.HitSide.FRONT, data), data.balf("combat.min_damage"), "schwache Waffe prallt ab, Mindestschaden bleibt")


func test_shot_hits_wolf_from_front() -> void:
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(4, 0)
	wolf.facing = Vector2.LEFT
	wolf.control = SimCharacter.Controller.NONE
	var hits := _tick(40, _shoot_intent(Vector2.RIGHT), "hit")
	assert_gt(hits.size(), 0, "getroffen")
	assert_eq(hits[0]["side"], SimCombat.HitSide.FRONT)
	assert_eq(hits[0]["damage"], float(data.items["sling"]["damage"]))
	assert_eq(hits[0]["attacker"], player.id)
	assert_lt(wolf.hp, wolf.max_hp)
	assert_eq(wolf.last_attacker_id, player.id)
	assert_true(SimSensors.is_under_attack(world, wolf))


func test_back_hit_doubles_damage() -> void:
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(4, 0)
	wolf.facing = Vector2.RIGHT  # schaut vom Spieler weg
	wolf.control = SimCharacter.Controller.NONE
	var hits := _tick(12, _shoot_intent(Vector2.RIGHT), "hit")
	assert_eq(hits.size(), 1)
	assert_eq(hits[0]["side"], SimCombat.HitSide.BACK)
	assert_eq(wolf.hp, wolf.max_hp - float(data.items["sling"]["damage"]) * data.balf("combat.back_damage_multiplier"))


func test_projectile_limit_and_cooldown() -> void:
	var intent := _shoot_intent(Vector2.RIGHT)
	var max_seen := 0
	for i in 60:
		world.set_intent(player.id, intent)
		world.tick()
		max_seen = maxi(max_seen, world.projectiles.size())
	assert_eq(max_seen, int(data.items["sling"]["max_projectiles"]), "nie mehr als das Limit in der Luft")
	var shots := _tick(1, intent, "shoot")
	world.projectiles.clear()
	shots = _tick(3, intent, "shoot")
	assert_lte(shots.size(), 1, "Cooldown verhindert Dauerfeuer")


func test_projectile_stops_at_wall_and_after_lifetime() -> void:
	player.pos = Vector2(2.5, 5.5)
	var walls := _tick(30, _shoot_intent(Vector2.LEFT), "projectile_wall")
	assert_gt(walls.size(), 0, "Projektil trifft die Randwand")
	player.pos = OPEN
	world.projectiles.clear()
	player.fire_cooldown = 0.0
	_tick(1, _shoot_intent(Vector2.RIGHT))
	assert_eq(world.projectiles.size(), 1)
	_tick(ceili(float(data.items["sling"]["projectile_lifetime"]) / world.tick_dt) + 2)
	assert_eq(world.projectiles.size(), 0, "Lebensdauer abgelaufen")


func test_wolf_approaches_and_bites() -> void:
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(5, 0)
	var start_distance := wolf.pos.distance_to(player.pos)
	var hits := _tick(60, null, "hit")
	assert_lt(wolf.pos.distance_to(player.pos), start_distance, "Wolf nähert sich")
	assert_eq(wolf.ai_state, WolfAI.STATE_CHASE)
	assert_gt(hits.size(), 0, "Wolf beißt")
	assert_lt(player.hp, player.max_hp)
	assert_eq(hits[0]["attacker"], wolf.id)


func test_wolf_ignores_hidden_player() -> void:
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(5, 0)
	player.hidden = true
	_tick(60)
	assert_eq(player.hp, player.max_hp)
	assert_eq(wolf.ai_state, WolfAI.STATE_WANDER)


func test_wolf_flees_when_low() -> void:
	var wolf := _wolf()
	wolf.pos = OPEN + Vector2(1, 0)
	wolf.hp = 5.0
	_tick(40)
	assert_eq(wolf.ai_state, WolfAI.STATE_FLEE)
	assert_gt(wolf.pos.distance_to(player.pos), 3.0, "Wolf läuft weg")


func test_kill_logs_chronicle_and_corpse_can_be_looted() -> void:
	var other := world.spawn_player(OPEN + Vector2(2, 0), "p2", "Fremder")
	other.facing = Vector2.LEFT
	other.inventory["berries"] = 3
	other.inventory["wood"] = 2
	var deaths := _tick(80, _shoot_intent(Vector2.RIGHT), "death")
	assert_eq(deaths.size(), 1, "drei Fronttreffer töten nackt")
	assert_true(other.dead)
	assert_eq(other.hp, 0.0)
	assert_eq(SimChronicle.format_all(other)[0].substr(8), "gestorben durch Du")
	player.pos = other.pos + Vector2(-1, 0)  # in Reichweite der Leiche
	var loot_intent := SimIntent.new()
	loot_intent.interact = true
	var loots := _tick(1, loot_intent, "loot")
	assert_eq(loots.size(), 1)
	assert_eq(player.inventory["berries"], 3)
	assert_eq(player.inventory["wood"], 2)
	assert_eq(other.inventory_count(), 0)
	var move := SimIntent.new()
	move.move = Vector2.RIGHT
	world.set_intent(other.id, move)
	var before := other.pos
	world.tick()
	assert_eq(other.pos, before, "Tote bewegen sich nicht")


func test_dead_wolf_is_replaced_after_respawn_time() -> void:
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			c.dead = true
	assert_eq(world.count_alive_wolves(), 0)
	_tick(ceili(data.balf("wolf.respawn_time") / world.tick_dt) + 1)
	assert_eq(world.count_alive_wolves(), 1, "ein Wolf nachgerückt")
	assert_eq(world.characters.size(), 2, "Kadaver entfernt")


func test_same_seed_same_result() -> void:
	var a := SimWorld.new(data, 99)
	a.setup_new_game()
	var b := SimWorld.new(data, 99)
	b.setup_new_game()
	for i in 600:
		a.tick()
		b.tick()
	for id: int in a.characters:
		assert_eq(a.characters[id].pos, b.characters[id].pos, "Charakter %d identisch" % id)
