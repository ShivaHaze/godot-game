class_name SimWorld
extends RefCounted
## Der komplette Weltzustand und der feste Tick. Keine Nodes, kein Rendering, kein Zugriff auf Input.
## Darstellung liest nur; Steuerung kommt als SimIntent pro Charakter herein.
## Zeitsprung = advance(): step() oft aufrufen, ohne zu zeichnen.

var data: SimData
var map: SimMap
var characters: Dictionary = {}          # id -> SimCharacter
var spatial := SimSpatial.new(4.0)      # Nachbarschaftsraster, pro Tick neu gefüllt
var lod_enabled: bool = true             # Simulationsstufen pro Charakter (false: alles fein, z. B. in Tests)
var observer_ids: Array[int] = []        # Charaktere, die wie Online-Spieler zählen (Zuschauer-Kamera)
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
	c.move_speed = data.balf("character.move_speed")
	c.collision_radius = data.balf("character.collision_radius")
	c.hunger = data.balf("hunger.start")
	for rid: String in data.resource_order:
		c.inventory[rid] = 0
	c.rules = data.default_rules.duplicate(true)
	for item_id: String in data.item_order:
		if data.items[item_id].get("starting", false):
			c.items.append(item_id)
			if c.active_weapon.is_empty() and data.items[item_id]["kind"] == "weapon":
				c.active_weapon = item_id
	refresh_equipment(c)
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
	c.marker_counter += 1
	var marker := {"id": "m%d" % c.marker_counter, "name": "Marker %d" % c.marker_counter, "pos": c.pos}
	c.markers.append(marker)
	events.append({"type": "marker", "id": id, "marker": marker})
	return marker


func rename_marker(id: int, marker_id: String, new_name: String) -> bool:
	var c := get_character(id)
	var trimmed := new_name.strip_edges()
	if c == null or trimmed.is_empty():
		return false
	for marker: Dictionary in c.markers:
		if marker["id"] == marker_id:
			marker["name"] = trimmed
			return true
	return false


## Entfernt einen Marker; Regeln, die ihn als Ort nutzen, fallen auf "Hier" zurück.
func remove_marker(id: int, marker_id: String) -> bool:
	var c := get_character(id)
	if c == null:
		return false
	for i in c.markers.size():
		if c.markers[i]["id"] == marker_id:
			c.markers.remove_at(i)
			for rule: Dictionary in c.rules:
				var params: Dictionary = rule["then"]["params"]
				if params.get("place", "") == marker_id:
					params["place"] = SimData.PLACE_HERE
			events.append({"type": "marker_removed", "id": id, "marker_id": marker_id})
			return true
	return false


## Ausloggen: der Charakter wird zum NPC und führt ab jetzt die Regelliste aus. "Hier" = aktuelle Position.
func logout(id: int, rules: Array, role_name: String = "") -> void:
	var c := get_character(id)
	c.control = SimCharacter.Controller.RULES
	c.rules = rules.duplicate(true)
	c.logout_pos = c.pos
	c.logout_time = time
	c.transition_logged = false
	c.leash_center = c.pos
	c.leash_radius = data.balf("npc.default_leash_radius")
	c.active_rule_index = -1
	c.skipped_rules = {}
	c.last_logged_rule_index = -1
	c.action_state = {}
	c.decision_timer = 0.0
	c.path.clear()
	c.chronicle.clear()
	SimChronicle.add(self, c, "ausgeloggt" + (" als %s" % role_name if not role_name.is_empty() else "") + " bei %s" % _pos_text(c.pos))
	events.append({"type": "logout", "id": id})


## Einloggen: der Spieler übernimmt seinen Charakter dort, wo er gerade ist.
func login(id: int) -> void:
	var c := get_character(id)
	c.control = SimCharacter.Controller.PLAYER
	c.active_rule_index = -1
	c.action_state = {}
	c.path.clear()
	c.leash_radius = 0.0
	SimChronicle.add(self, c, "eingeloggt bei %s" % _pos_text(c.pos))
	events.append({"type": "login", "id": id})


## Ende des Logout-Übergangs: transition_seconds nach dem Ausloggen, bei Kampf erst combat_window nach dem letzten Schaden.
func transition_end(c: SimCharacter) -> float:
	var combat_free := c.last_damage_time + data.balf("logout.combat_window")
	return maxf(c.logout_time, combat_free) + data.balf("logout.transition_seconds")


## Läuft der Übergang noch? Solange ist der Charakter verwundbar und kann sich nicht verstecken.
func in_transition(c: SimCharacter) -> bool:
	return c.control == SimCharacter.Controller.RULES and time < transition_end(c)


static func _pos_text(pos: Vector2) -> String:
	return "(%d, %d)" % [int(pos.x), int(pos.y)]


# --- Ausrüstung -----------------------------------------------------------

## Leitet Rüstung und Nahkampfwerte aus den besessenen Gegenständen ab (nur Spielercharaktere).
func refresh_equipment(c: SimCharacter) -> void:
	if c.kind != SimCharacter.Kind.PLAYER:
		return
	var best_armor := 0.0
	for item_id: String in c.items:
		var def: Dictionary = data.items.get(item_id, {})
		if def.get("kind", "") == "armor":
			best_armor = maxf(best_armor, float(def["armor"]))
	c.armor = data.balf("character.armor") + best_armor
	if not c.items.has(c.active_weapon):
		c.active_weapon = ""
		for item_id: String in c.items:
			if data.items[item_id]["kind"] == "weapon":
				c.active_weapon = item_id
				break
	var weapon: Dictionary = data.items.get(c.active_weapon, {})
	if weapon.get("attack", "") == "melee":
		c.melee_damage = float(weapon["damage"])
		c.melee_range = float(weapon["range"])
		c.melee_cooldown = float(weapon["cooldown"])
	else:
		c.melee_damage = 0.0


## Werkbank: baut einen Gegenstand aus dem Inventar. Rückgabe: leer = gebaut, sonst der Grund.
func craft(c: SimCharacter, item_id: String) -> String:
	var def: Dictionary = data.items.get(item_id, {})
	if def.is_empty():
		return "unbekannter Gegenstand"
	if c.items.has(item_id):
		return "schon vorhanden"
	var cost: Dictionary = def.get("cost", {})
	if cost.is_empty():
		return "nicht baubar"
	for rid: String in cost:
		var needed := int(cost[rid])
		if int(c.inventory.get(rid, 0)) < needed:
			return "zu wenig %s (%d nötig)" % [data.resources[rid]["name"], needed]
	for rid: String in cost:
		c.inventory[rid] = int(c.inventory[rid]) - int(cost[rid])
	c.items.append(item_id)
	refresh_equipment(c)
	events.append({"type": "craft", "id": c.id, "item": item_id})
	return ""


func set_active_weapon(c: SimCharacter, item_id: String) -> bool:
	if not c.items.has(item_id) or data.items.get(item_id, {}).get("kind", "") != "weapon":
		return false
	c.active_weapon = item_id
	refresh_equipment(c)
	return true


func owned_weapons(c: SimCharacter) -> Array[String]:
	var result: Array[String] = []
	for item_id: String in c.items:
		if data.items.get(item_id, {}).get("kind", "") == "weapon":
			result.append(item_id)
	return result


# --- Tick -----------------------------------------------------------------

func tick() -> void:
	step(tick_dt)


## Ein Simulationsschritt von dt Sekunden. Reihenfolge: Controller -> Absichten -> Projektile -> Unterhalt -> Welt.
## Simulationsstufen: Charaktere ohne Online-Spieler in offline.lod_radius rechnen nur alle coarse_tick_dt
## Sekunden (mit entsprechend großem Schritt), alle anderen jeden Tick.
func step(dt: float) -> void:
	events.clear()
	tick_count += 1
	time += dt
	for c: SimCharacter in characters.values():
		c.prev_pos = c.pos
	for p: SimProjectile in projectiles:
		p.prev_pos = p.pos
	spatial.rebuild(characters)
	var coarse_dt := data.balf("offline.coarse_tick_dt")
	var lod_radius := data.balf("offline.lod_radius")
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		var step_dt := dt
		if lod_enabled and c.control != SimCharacter.Controller.PLAYER and dt < coarse_dt and not _near_online(c, lod_radius):
			c.lod_accumulator += dt
			if c.lod_accumulator + 1e-6 < coarse_dt:
				continue
			step_dt = c.lod_accumulator
			c.lod_accumulator = 0.0
			c.lod_coarse_steps += 1
		else:
			c.lod_accumulator = 0.0
			c.lod_fine_steps += 1
		var intent: SimIntent = _intents.get(c.id, null)
		match c.control:
			SimCharacter.Controller.WOLF_AI:
				intent = WolfAI.decide(self, c, step_dt)
			SimCharacter.Controller.RULES:
				intent = NpcController.decide(self, c, step_dt)
		_apply_intent(c, intent if intent != null else SimIntent.new(), step_dt)
	_intents.clear()
	spatial.rebuild(characters)
	_update_projectiles(dt)
	_update_hunger(dt)
	_update_nodes(dt)
	_update_wolves(dt)


## Ist ein lebender Online-Spieler (vom Spieler gesteuert oder beobachtet) in Reichweite?
func _near_online(c: SimCharacter, radius: float) -> bool:
	if observer_ids.has(c.id):
		return true
	for other: SimCharacter in spatial.query(c.pos, radius):
		if other.dead or other.pos.distance_to(c.pos) > radius:
			continue
		if other.control == SimCharacter.Controller.PLAYER or observer_ids.has(other.id):
			return true
	return false


## Lebende Charaktere im Radius (Kandidaten aus dem Raster, Distanz geprüft).
func near(pos: Vector2, radius: float) -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	var r2 := radius * radius
	for c: SimCharacter in spatial.query(pos, radius):
		if not c.dead and c.pos.distance_squared_to(pos) <= r2:
			result.append(c)
	return result


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
		_attack(c)
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


## Plündert eine Leiche in Reichweite: Rohstoffe (so viel Platz ist) und Ausrüstung, die man noch nicht hat.
func _loot(c: SimCharacter) -> bool:
	var range_sq := pow(data.balf("character.interact_range"), 2.0)
	for other: SimCharacter in characters.values():
		if other == c or not other.dead:
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
		var items_taken: Array[String] = []
		if c.kind == SimCharacter.Kind.PLAYER:
			for item_id: String in other.items.duplicate():
				if not c.items.has(item_id):
					other.items.erase(item_id)
					c.items.append(item_id)
					items_taken.append(item_id)
		if taken.is_empty() and items_taken.is_empty():
			continue
		refresh_equipment(c)
		refresh_equipment(other)
		events.append({"type": "loot", "id": c.id, "from": other.id, "items": taken, "equipment": items_taken})
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

## Angriff mit der aktiven Waffe: Fernkampf schießt ein Projektil, Nahkampf schlägt zu.
func _attack(c: SimCharacter) -> void:
	var weapon: Dictionary = data.items.get(c.active_weapon, {})
	if weapon.is_empty():
		return
	if weapon.get("attack", "") == "ranged":
		_shoot(c, weapon)
	else:
		_melee(c)


func _shoot(c: SimCharacter, weapon: Dictionary) -> void:
	if c.fire_cooldown > 0.0 or projectile_count(c.id) >= int(weapon["max_projectiles"]):
		return
	if c.facing == Vector2.ZERO:
		return
	var p := SimProjectile.new()
	p.owner_id = c.id
	p.pos = c.pos + c.facing * (c.collision_radius + 0.15)
	p.prev_pos = p.pos
	p.velocity = c.facing * float(weapon["projectile_speed"])
	p.damage = float(weapon["damage"])
	p.lifetime = float(weapon["projectile_lifetime"])
	projectiles.append(p)
	c.fire_cooldown = float(weapon["cooldown"])
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
	for other: SimCharacter in spatial.query(c.pos, radius):
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
	for c: SimCharacter in spatial.query(p.pos, 1.0):
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
	var reveal_radius := data.balf("npc.reveal_radius")
	for c: SimCharacter in characters.values():
		if c.dead:
			continue
		if c.kind == SimCharacter.Kind.WOLF and c.ai_state == WolfAI.STATE_WANDER and c.hp < c.max_hp and not SimSensors.is_under_attack(self, c):
			c.hp = minf(c.max_hp, c.hp + regen * dt)
		if not c.hidden:
			continue
		# Wer über einen Versteckten läuft, entdeckt ihn
		for other: SimCharacter in spatial.query(c.pos, reveal_radius):
			if other != c and not other.dead and other.owner_id != c.owner_id and other.pos.distance_squared_to(c.pos) <= reveal_radius_sq:
				reveal(c)
				events.append({"type": "discovered", "id": c.id, "by": other.id})
				break
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


# --- Zeitsprung -----------------------------------------------------------

## Simuliert `seconds` Sim-Sekunden ohne Darstellung (Simulationsstufen): grob mit offline.coarse_tick_dt,
## solange kein Spielercharakter in Gefahr ist und nichts fliegt, sonst fein mit tick_dt. Gibt die Schrittzahl zurück.
func advance(seconds: float) -> int:
	var target := time + seconds
	var steps := 0
	while time < target - 1e-6:
		_advance_one(target)
		steps += 1
	return steps


## Wie advance(), aber höchstens budget_msec Echtzeit am Stück (für eine Fortschrittsanzeige). true = Ziel erreicht.
func advance_until(target_time: float, budget_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + budget_msec
	while time < target_time - 1e-6:
		_advance_one(target_time)
		if Time.get_ticks_msec() >= deadline:
			break
	return time >= target_time - 1e-6


func _advance_one(target_time: float) -> void:
	var dt := tick_dt if is_hot() else data.balf("offline.coarse_tick_dt")
	step(minf(dt, target_time - time))


## Gefahr in der Nähe eines Spielercharakters (oder Projektile in der Luft)? Dann fein simulieren.
func is_hot() -> bool:
	if not projectiles.is_empty():
		return true
	spatial.rebuild(characters)  # Positionen können sich seit dem letzten Tick geändert haben
	var radius := data.balf("offline.hot_radius")
	for c: SimCharacter in characters.values():
		if c.dead or c.kind != SimCharacter.Kind.PLAYER:
			continue
		if SimSensors.is_under_attack(self, c) or nearest_enemy(c, radius) != null:
			return true
	return false


# --- Abfragen -------------------------------------------------------------

## Uhrzeit "HH:MM" für eine Sim-Zeit (Standard: jetzt).
func clock_string(t: float = -1.0) -> String:
	if t < 0.0:
		t = time
	var total_minutes := (data.bali("clock_start_hour") * 60 + int(t / 60.0)) % (24 * 60)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]
