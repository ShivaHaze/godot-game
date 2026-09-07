class_name SimWorld
extends RefCounted
## Der komplette Weltzustand und der feste Tick. Keine Nodes, kein Rendering, kein Zugriff auf Input.
## Darstellung liest nur; Steuerung kommt als SimIntent pro Charakter herein.
## Zeitsprung = step() oft aufrufen, ohne zu zeichnen.

var data: SimData
var map: SimMap
var characters: Dictionary = {}          # id -> SimCharacter
var projectiles: Array[SimProjectile] = []
var events: Array[Dictionary] = []       # Ereignisse des letzten Ticks (für Darstellung/Chronik)
var time: float = 0.0                    # Sim-Sekunden seit Spielstart
var tick_count: int = 0
var tick_dt: float = 0.05
var rng := RandomNumberGenerator.new()

var _next_id: int = 1
var _intents: Dictionary = {}            # id -> SimIntent, gilt nur für den nächsten Tick
var _wolf_respawn_timer: float = 0.0


func _init(p_data: SimData, seed: int = 12345) -> void:
	data = p_data
	map = SimMap.new(data)
	tick_dt = 1.0 / data.balf("tick_rate")
	rng.seed = seed


# --- Aufbau ---------------------------------------------------------------

## Startet ein neues Spiel: Spieler am Spawn, Wölfe an ihren Spawns. Gibt die Spieler-Kennung zurück.
func setup_new_game() -> int:
	var player := spawn_player(SimMap.cell_center(data.player_spawns[0]), "p1", "Du")
	for cell: Vector2i in data.wolf_spawns:
		if count_alive_wolves() >= data.bali("wolf.max_alive"):
			break
		spawn_wolf(SimMap.cell_center(cell))
	return player.id


func spawn_player(pos: Vector2, owner_id: String, display_name: String) -> SimCharacter:
	var c := SimCharacter.new()
	c.id = _next_id
	_next_id += 1
	c.name = display_name
	c.kind = SimCharacter.Kind.PLAYER
	c.control = SimCharacter.Controller.PLAYER
	c.owner_id = owner_id
	c.pos = pos
	c.prev_pos = pos
	c.logout_pos = pos
	c.max_hp = data.balf("character.max_hp")
	c.hp = c.max_hp
	c.armor = data.balf("character.armor")
	c.move_speed = data.balf("character.move_speed")
	c.collision_radius = data.balf("character.collision_radius")
	c.hunger = data.balf("hunger.start")
	for rid: String in data.resource_order:
		c.inventory[rid] = 0
	c.rules = data.default_rules.duplicate(true)
	characters[c.id] = c
	return c


func spawn_wolf(pos: Vector2) -> SimCharacter:
	var c := SimCharacter.new()
	c.id = _next_id
	_next_id += 1
	c.name = "Wolf %d" % c.id
	c.kind = SimCharacter.Kind.WOLF
	c.control = SimCharacter.Controller.WOLF_AI
	c.owner_id = "wild"
	c.pos = pos
	c.prev_pos = pos
	c.home_pos = pos
	c.ai_target_pos = pos
	c.max_hp = data.balf("wolf.max_hp")
	c.hp = c.max_hp
	c.armor = data.balf("wolf.armor")
	c.move_speed = data.balf("wolf.move_speed")
	c.collision_radius = data.balf("character.collision_radius")
	c.melee_damage = data.balf("wolf.bite_damage")
	c.melee_range = data.balf("wolf.bite_range")
	c.melee_cooldown = data.balf("wolf.bite_cooldown")
	c.hunger = data.balf("hunger.max")
	characters[c.id] = c
	return c


func count_alive_wolves() -> int:
	var n := 0
	for c: SimCharacter in characters.values():
		if c.kind == SimCharacter.Kind.WOLF and not c.dead:
			n += 1
	return n


func get_character(id: int) -> SimCharacter:
	return characters.get(id)


func alive_characters() -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	for c: SimCharacter in characters.values():
		if not c.dead:
			result.append(c)
	return result


func projectile_count(owner_id: int) -> int:
	var n := 0
	for p: SimProjectile in projectiles:
		if p.owner_id == owner_id:
			n += 1
	return n


# --- Steuerung ------------------------------------------------------------

func set_intent(id: int, intent: SimIntent) -> void:
	_intents[id] = intent


## Setzt einen Marker an der aktuellen Position des Charakters. Nur Marker sind als Ort in Regeln wählbar.
func add_marker(id: int) -> Dictionary:
	var c := get_character(id)
	var marker := {"id": "m%d" % (c.markers.size() + 1), "name": "Marker %d" % (c.markers.size() + 1), "pos": c.pos}
	c.markers.append(marker)
	events.append({"type": "marker", "id": id, "marker": marker})
	return marker


# --- Tick -----------------------------------------------------------------

func tick() -> void:
	step(tick_dt)


## Ein Simulationsschritt von dt Sekunden. Reihenfolge: Controller -> Absichten -> Projektile -> Unterhalt -> Welt.
func step(dt: float) -> void:
	events.clear()
	tick_count += 1
	time += dt
	for c: SimCharacter in characters.values():
		c.prev_pos = c.pos
	for p: SimProjectile in projectiles:
		p.prev_pos = p.pos
	_run_controllers(dt)
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		var intent: SimIntent = _intents.get(c.id, null)
		_apply_intent(c, intent if intent != null else SimIntent.new(), dt)
	_intents.clear()
	_update_projectiles(dt)
	_update_hunger(dt)
	_update_nodes(dt)
	_update_wolves(dt)


## Controller für nicht vom Spieler gesteuerte Charaktere erzeugen ihre Absichten.
func _run_controllers(dt: float) -> void:
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		match c.control:
			SimCharacter.Controller.WOLF_AI:
				_intents[c.id] = WolfAI.decide(self, c, dt)
			SimCharacter.Controller.RULES:
				_intents[c.id] = NpcController.decide(self, c, dt)


func _apply_intent(c: SimCharacter, intent: SimIntent, dt: float) -> void:
	if intent.aim != Vector2.ZERO:
		c.facing = intent.aim.normalized()
	elif intent.move != Vector2.ZERO:
		c.facing = intent.move.normalized()

	var move := intent.move
	if move.length_squared() > 1.0:
		move = move.normalized()
	if move != Vector2.ZERO:
		var speed := c.move_speed
		if c.is_weakened():
			speed *= data.balf("character.weakened_speed_multiplier")
		c.pos = map.resolve_move(c.pos, move * speed * dt, c.collision_radius)
		if c.hidden:
			reveal(c)

	if intent.interact:
		if not _loot(c):
			_gather(c, dt)
	else:
		c.gather_progress = 0.0
		c.gather_target = Vector2i(-1, -1)

	if intent.eat:
		eat(c)
	if intent.shoot:
		_shoot(c)
	if intent.melee:
		_melee(c)
	_update_hiding(c, intent, dt)

	c.fire_cooldown = maxf(0.0, c.fire_cooldown - dt)
	c.bite_cooldown = maxf(0.0, c.bite_cooldown - dt)


func _gather(c: SimCharacter, dt: float) -> void:
	var node := map.nearest_node(c.pos, data.balf("character.interact_range"), "", true)
	if node == null or c.inventory_count() >= data.bali("inventory.capacity"):
		c.gather_progress = 0.0
		c.gather_target = Vector2i(-1, -1)
		return
	if node.cell != c.gather_target:
		c.gather_progress = 0.0
		c.gather_target = node.cell
	c.gather_progress += dt
	var gather_time := data.balf("gathering.gather_time")
	while c.gather_progress + 0.0001 >= gather_time and node.amount > 0 and c.inventory_count() < data.bali("inventory.capacity"):
		c.gather_progress -= gather_time
		node.amount -= 1
		c.inventory[node.resource] = int(c.inventory.get(node.resource, 0)) + 1
		events.append({"type": "gather", "id": c.id, "resource": node.resource, "cell": node.cell})


## Plündert eine Leiche in Reichweite (alles auf einmal). true, wenn etwas übernommen wurde.
func _loot(c: SimCharacter) -> bool:
	var range_sq := pow(data.balf("character.interact_range"), 2.0)
	for other: SimCharacter in characters.values():
		if other == c or not other.dead or other.inventory_count() <= 0:
			continue
		if other.pos.distance_squared_to(c.pos) > range_sq:
			continue
		var taken := {}
		var capacity := data.bali("inventory.capacity")
		for rid: String in data.resource_order:
			var amount := int(other.inventory.get(rid, 0))
			var room := capacity - c.inventory_count()
			var moved := mini(amount, room)
			if moved <= 0:
				continue
			other.inventory[rid] = amount - moved
			c.inventory[rid] = int(c.inventory.get(rid, 0)) + moved
			taken[rid] = moved
		if taken.is_empty():
			return false
		events.append({"type": "loot", "id": c.id, "from": other.id, "items": taken})
		return true
	return false


## Isst ein essbares Stück. Gibt das Ereignis zurück (leer, wenn nichts gegessen wurde).
func eat(c: SimCharacter) -> Dictionary:
	var hunger_max := data.balf("hunger.max")
	if c.hunger >= hunger_max:
		return {}
	for rid: String in data.resource_order:
		var def: Dictionary = data.resources[rid]
		if not def.get("edible", false) or int(c.inventory.get(rid, 0)) <= 0:
			continue
		var before := int(c.inventory[rid])
		c.inventory[rid] = before - 1
		c.hunger = minf(hunger_max, c.hunger + float(def["nutrition"]))
		var event := {"type": "eat", "id": c.id, "resource": rid, "before": before, "after": before - 1}
		events.append(event)
		return event
	return {}


# --- Kampf ----------------------------------------------------------------

func _shoot(c: SimCharacter) -> void:
	if c.fire_cooldown > 0.0 or projectile_count(c.id) >= data.bali("combat.max_projectiles_per_shooter"):
		return
	if c.facing == Vector2.ZERO:
		return
	var p := SimProjectile.new()
	p.owner_id = c.id
	p.pos = c.pos + c.facing * (c.collision_radius + 0.15)
	p.prev_pos = p.pos
	p.velocity = c.facing * data.balf("combat.projectile_speed")
	p.damage = data.balf("combat.projectile_damage")
	p.lifetime = data.balf("combat.projectile_lifetime")
	projectiles.append(p)
	c.fire_cooldown = data.balf("combat.fire_cooldown")
	reveal(c)
	events.append({"type": "shoot", "id": c.id})


func _melee(c: SimCharacter) -> void:
	if c.bite_cooldown > 0.0 or c.melee_damage <= 0.0:
		return
	var target := nearest_enemy(c, c.melee_range)
	if target == null:
		return
	c.bite_cooldown = c.melee_cooldown
	reveal(c)
	apply_damage(target, c.melee_damage, (target.pos - c.pos).normalized(), c.id)


## Nächster lebender, sichtbarer Charakter eines anderen Besitzers im Radius.
func nearest_enemy(c: SimCharacter, radius: float) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for other: SimCharacter in characters.values():
		if other == c or other.dead or other.hidden or other.owner_id == c.owner_id:
			continue
		var d := other.pos.distance_squared_to(c.pos)
		if d <= best_d:
			best_d = d
			best = other
	return best


func _update_projectiles(dt: float) -> void:
	var i := 0
	while i < projectiles.size():
		var p: SimProjectile = projectiles[i]
		var removed := false
		var steps := maxi(1, ceili(p.velocity.length() * dt / SimMap.MOVE_SUBSTEP))
		var part := p.velocity * dt / float(steps)
		for s in steps:
			p.pos += part
			if not map.is_walkable(SimMap.cell_of(p.pos)):
				events.append({"type": "projectile_wall", "pos": p.pos})
				removed = true
				break
			var victim := _projectile_victim(p)
			if victim != null:
				apply_damage(victim, p.damage, p.velocity.normalized(), p.owner_id)
				removed = true
				break
		p.lifetime -= dt
		if p.lifetime <= 0.0:
			removed = true
		if removed:
			projectiles.remove_at(i)
		else:
			i += 1


func _projectile_victim(p: SimProjectile) -> SimCharacter:
	for c: SimCharacter in characters.values():
		if c.dead or c.hidden or c.id == p.owner_id:
			continue
		var r := c.collision_radius + 0.1
		if c.pos.distance_squared_to(p.pos) < r * r:
			return c
	return null


## Fügt Schaden mit Richtungstreffer zu. hit_dir = Flugrichtung des Treffers (Angreifer -> Opfer).
func apply_damage(victim: SimCharacter, base_damage: float, hit_dir: Vector2, attacker_id: int) -> Dictionary:
	var side := SimCombat.hit_side(victim.facing, hit_dir, data.balf("combat.front_arc_degrees"), data.balf("combat.back_arc_degrees"))
	var amount := SimCombat.damage(base_damage, victim.armor, side, data)
	victim.hp = maxf(0.0, victim.hp - amount)
	victim.last_damage_time = time
	victim.last_attacker_id = attacker_id
	reveal(victim)
	var event := {"type": "hit", "id": victim.id, "attacker": attacker_id, "damage": amount, "side": side, "pos": victim.pos}
	events.append(event)
	if victim.hp <= 0.0:
		_kill(victim, attacker_id)
	return event


func _kill(victim: SimCharacter, attacker_id: int) -> void:
	victim.dead = true
	victim.hp = 0.0
	victim.hidden = false
	victim.death_time = time
	var attacker := get_character(attacker_id)
	var attacker_name := attacker.name if attacker != null else "Unbekannt"
	events.append({"type": "death", "id": victim.id, "attacker": attacker_id})
	if victim.kind == SimCharacter.Kind.PLAYER:
		SimChronicle.add(self, victim, "gestorben durch %s" % attacker_name)
	if attacker != null and attacker.kind == SimCharacter.Kind.PLAYER and attacker.control == SimCharacter.Controller.RULES:
		SimChronicle.add(self, attacker, "%s getötet" % victim.name)


# --- Verstecken -----------------------------------------------------------

## Verstecken braucht hide_delay Sekunden ohne Schaden und ohne Bewegung; Entdeckte müssen warten.
func _update_hiding(c: SimCharacter, intent: SimIntent, dt: float) -> void:
	if c.hidden:
		return
	if not intent.hide or intent.move != Vector2.ZERO or time < c.revealed_until:
		c.hide_progress = 0.0
		return
	c.hide_progress += dt
	if c.hide_progress >= data.balf("npc.hide_delay"):
		c.hidden = true
		c.hide_progress = 0.0
		events.append({"type": "hidden", "id": c.id})


## Macht einen Versteckten sichtbar (Schaden, Bewegung, Schuss, Entdeckung).
func reveal(c: SimCharacter) -> void:
	c.hide_progress = 0.0
	c.revealed_until = time + data.balf("npc.reveal_duration")
	if c.hidden:
		c.hidden = false
		events.append({"type": "revealed", "id": c.id})


# --- Unterhalt und Welt ---------------------------------------------------

func _update_hunger(dt: float) -> void:
	var live_rate := data.balf("hunger.decay_per_second_live")
	var offline_rate := data.balf("hunger.decay_per_second_offline")
	for c: SimCharacter in characters.values():
		if c.dead or c.kind != SimCharacter.Kind.PLAYER:
			continue
		var rate := live_rate if c.control == SimCharacter.Controller.PLAYER else offline_rate
		c.hunger = maxf(0.0, c.hunger - rate * dt)


func _update_nodes(dt: float) -> void:
	var regrow := data.balf("gathering.node_regrow_time")
	for node: SimResourceNode in map.nodes.values():
		if node.amount >= node.max_amount:
			node.regrow_timer = 0.0
			continue
		node.regrow_timer += dt
		while node.regrow_timer >= regrow and node.amount < node.max_amount:
			node.regrow_timer -= regrow
			node.amount += 1


## Wölfe: Entdeckung Versteckter, Erholung beim Streunen, Nachschub nach respawn_time.
func _update_wolves(dt: float) -> void:
	var reveal_radius_sq := pow(data.balf("npc.reveal_radius"), 2.0)
	var regen := data.balf("wolf.regen_per_second")
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		if c.kind == SimCharacter.Kind.WOLF and c.ai_state == WolfAI.STATE_WANDER and c.hp < c.max_hp and not SimSensors.is_under_attack(self, c):
			c.hp = minf(c.max_hp, c.hp + regen * dt)
		# Wer über einen Versteckten läuft, entdeckt ihn
		for other: SimCharacter in characters.values():
			if other.hidden and not other.dead and other.owner_id != c.owner_id and other.pos.distance_squared_to(c.pos) <= reveal_radius_sq:
				reveal(other)
				events.append({"type": "discovered", "id": other.id, "by": c.id})
	if count_alive_wolves() >= data.bali("wolf.max_alive") or data.wolf_spawns.is_empty():
		_wolf_respawn_timer = 0.0
		return
	_wolf_respawn_timer += dt
	if _wolf_respawn_timer >= data.balf("wolf.respawn_time"):
		_wolf_respawn_timer = 0.0
		for id: int in characters.keys():
			var c: SimCharacter = characters[id]
			if c.kind == SimCharacter.Kind.WOLF and c.dead:
				characters.erase(id)
		var cell: Vector2i = data.wolf_spawns[rng.randi_range(0, data.wolf_spawns.size() - 1)]
		spawn_wolf(SimMap.cell_center(cell))


# --- Abfragen -------------------------------------------------------------

## Uhrzeit "HH:MM" für eine Sim-Zeit (Standard: jetzt).
func clock_string(t: float = -1.0) -> String:
	if t < 0.0:
		t = time
	var total_minutes := (data.bali("clock_start_hour") * 60 + int(t / 60.0)) % (24 * 60)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]
