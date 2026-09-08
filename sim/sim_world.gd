class_name SimWorld
extends RefCounted
## Der komplette Weltzustand und der feste Tick. Keine Nodes, kein Rendering, kein Zugriff auf Input.
## Darstellung liest nur; Steuerung kommt als SimIntent pro Charakter herein.
## Zeitsprung = advance(): step() oft aufrufen, ohne zu zeichnen.
## Die Fachlogik liegt in statischen Modulen mit der Welt als erstem Parameter: SimCrafting (Herstellen, Ausrüstung),
## SimEffects (Zustandseffekte), SimConstruction (Bauen), SimDefense (Sensoren, Fallen, Turrets, Sprengsätze),
## SimTrade (Handelstisch, Depots, Lieferung), SimToll (Zoll), SimEvents (Leitwolf), SimCombat (Treffer, Projektile, Tod).
## Hier bleiben Zustand, Aufbau, Absichten, Aus-/Einloggen, Tick und Simulationsstufen, Sammeln, Plündern, Essen,
## Hunger, Wölfe, Verstecken, Orte, Namen, Briefe und der Zeitsprung.


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


var claims := SimClaims.new()            # Land: Anker, Kacheln, Unterhalt


var guilds := SimGuilds.new()            # Gilden: Verbündete teilen Claims, Türen und Alarm


var _next_id: int = 1


var _next_building_id: int = 1


var _intents: Dictionary = {}            # id -> SimIntent, gilt nur für den nächsten Tick


var _wolf_respawn_timer: float = 0.0


var next_boss_time: float = -1.0         # Sim-Zeit, zu der der nächste Leitwolf erscheint (Ereignis); < 0 = keine Ereignisse
var next_caravan_time: float = -1.0      # Sim-Zeit, zu der die nächste Karawane aufbricht
var caravans: Dictionary = {}            # Karawanen (SimEvents): id -> {leader, members, stop, leg, goal, target, rest_until, raided_at}
var next_caravan_id: int = 1


func _init(p_data: SimData, seed: int = 12345) -> void:
	data = p_data
	map = SimMap.new(data)
	map.guilds = guilds
	claims.guilds = guilds
	tick_dt = 1.0 / data.balf("tick_rate")
	rng.seed = seed
	next_boss_time = data.balf("events.boss.first_after_hours") * 3600.0
	next_caravan_time = data.balf("events.caravan.first_after_hours") * 3600.0


# --- Aufbau ---------------------------------------------------------------


## Startet ein neues Spiel: Spieler am Spawn, Wölfe an ihren Spawns. Gibt die Spieler-Kennung zurück.
func setup_new_game() -> int:
	for cell: Vector2i in data.depot_spawns:
		spawn_depot(cell)
	var player := spawn_player(SimMap.cell_center(data.player_spawns[0]), "p1", "Du")
	for cell: Vector2i in data.wolf_spawns:
		if count_alive_wolves() >= data.bali("wolf.max_alive"):
			break
		spawn_wolf(SimMap.cell_center(cell))
	return player.id


## Neutrales Markt-Depot (Kartenfeature): gehört niemandem, unzerstörbar, für alle ein Ort.
func spawn_depot(cell: Vector2i) -> SimBuilding:
	var b := spawn_building("depot", cell, "")
	if b == null:
		return null
	var zone := zone_def(map.zone(cell))
	var count := 0
	for other: SimBuilding in SimTrade.depots(self):
		if map.zone(SimMap.cell_of(other.center())) == map.zone(cell):
			count += 1
	b.label = "%s %d" % [zone.get("depot_label", "Depot"), count]
	return b


## Setzt ein Bauteil ohne Kosten und Regeln auf eine Kachel (Kartenfeatures, Werkzeuge, Tests). null bei unbekanntem Teil.
func spawn_building(part: String, cell: Vector2i, owner_id: String) -> SimBuilding:
	if not data.buildings.has(part):
		return null
	var def: Dictionary = data.buildings[part]
	var b := SimBuilding.new()
	b.id = _next_building_id
	_next_building_id += 1
	b.part = part
	b.owner_id = owner_id
	b.origin = cell * 2
	b.max_hp = float(def["hp"])
	b.hp = b.max_hp
	b.placed_time = time
	b.cells = SimBuilding.cells_for(def["size"], b.origin, 0)
	map.add_building(b)
	if not owner_id.is_empty() and (SimDefense.is_sensor(self, b) or SimTrade.is_container(self, b)):
		refresh_places(owner_id)
	return b


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
			c.durability[item_id] = {"left": float(data.items[item_id]["durability"]), "max": float(data.items[item_id]["durability"])}
			if c.active_weapon.is_empty() and data.items[item_id]["kind"] == "weapon":
				c.active_weapon = item_id
	SimCrafting.refresh_equipment(self, c)
	characters[c.id] = c
	refresh_places(owner_id)
	return c


func spawn_wolf(pos: Vector2) -> SimCharacter:
	var c := SimCharacter.new()
	c.id = _next_id
	_next_id += 1
	c.name = "Wolf %d" % c.id
	c.kind = SimCharacter.Kind.WOLF
	c.control = SimCharacter.Controller.WOLF_AI
	c.owner_id = "wild"
	for rid: Variant in data.balance.get("wolf", {}).get("loot", {"meat": 2}):
		if data.resources.has(rid):
			c.inventory[String(rid)] = int(data.balance["wolf"]["loot"][rid])  # Beute der Leiche: Fleisch und Fell
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


## Wo ein neuer Charakter dieses Besitzers erscheint: neben dem eigenen Spawn-Anker, sonst am Kartenrand.
func spawn_point_for(owner_id: String) -> Vector2:
	for b: SimBuilding in map.buildings.values():
		if b.owner_id == owner_id and bool(data.buildings.get(b.part, {}).get("spawn", false)):
			var origin := SimMap.cell_of(b.center())
			for ring in range(1, 5):
				for dy in range(-ring, ring + 1):
					for dx in range(-ring, ring + 1):
						if maxi(absi(dx), absi(dy)) != ring:
							continue
						var cell := origin + Vector2i(dx, dy)
						if map.is_walkable_for(cell, owner_id, data) and not map.built_half.has(cell * 2):
							return SimMap.cell_center(cell)
	return random_player_spawn()


## Ein Spieler-Spawn (bei mehreren zufällig, Design: gewichtete Spawn-Zonen kommen später).
func random_player_spawn() -> Vector2:
	var cell: Vector2i = data.player_spawns[rng.randi_range(0, data.player_spawns.size() - 1)]
	return SimMap.cell_center(cell)


func count_alive_wolves() -> int:
	var n := 0
	for c: SimCharacter in characters.values():
		if c.kind == SimCharacter.Kind.WOLF and not c.dead and not c.boss:
			n += 1
	return n


func get_character(id: int) -> SimCharacter:
	return characters.get(id)


## Nächste freie Charakter-Kennung (für Module, die Charaktere erzeugen).
func allocate_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


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
	var pushed := _push_out_of_foreign_claim(c)
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
	refresh_places(c.owner_id)
	SimChronicle.add(self, c, "ausgeloggt" + (" als %s" % role_name if not role_name.is_empty() else "") + " bei %s" % _pos_text(c.pos) + (" (aus fremdem Claim geschoben)" if pushed else ""))
	events.append({"type": "logout", "id": id})


## In fremdem Claim kann kein Offline-Charakter aktiviert werden: zur nächsten freien Kachel schieben.
func _push_out_of_foreign_claim(c: SimCharacter) -> bool:
	var start := SimMap.cell_of(c.pos)
	if not claims.is_foreign(start, c.owner_id):
		return false
	for ring in range(1, 30):
		var best := Vector2i(-1, -1)
		var best_d := 1e9
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var tile := start + Vector2i(dx, dy)
				if map.is_walkable_for(tile, c.owner_id, data) and not claims.is_foreign(tile, c.owner_id):
					var d := Vector2(dx, dy).length_squared()
					if d < best_d:
						best_d = d
						best = tile
		if best.x >= 0:
			c.pos = SimMap.cell_center(best)
			c.prev_pos = c.pos
			return true
	return false


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


# --- Voraussetzungen für Regel-Bausteine ----------------------------------
## Bausteine werden nie freigeschaltet (Entscheidung 2026-09-08). Manche brauchen etwas in der Welt: einen eigenen
## Claim ("Fremder im eigenen Claim", "verlange Zoll") oder einen eigenen Sensor ("Sensor … ausgelöst"). Der Editor
## graut sie sonst aus, ein NPC überspringt die Regel mit Grund. Der Client-Spiegel bekommt den Stand vom Server.


var prereqs_override: Dictionary = {}    # Besitzer -> {fact: bool}; nur im Client-Spiegel gesetzt (Selbstblock)


## Aktueller Stand der Voraussetzungen eines Besitzers (Gildenbauteile zählen mit).
func prerequisites_of(owner_id: String) -> Dictionary:
	if prereqs_override.has(owner_id):
		return prereqs_override[owner_id]
	return {
		"own_claim": claims.claim_of_owner(owner_id) != null,
		"own_sensor": not SimDefense.sensors_of(self, owner_id, true).is_empty(),
	}


## Ist ein Baustein für den Besitzer dieses Charakters gerade verfügbar?
func can_use(c: SimCharacter, def: Dictionary) -> bool:
	return data.is_available(def, prerequisites_of(c.owner_id))


# --- Orte aus Bauteilen und Leichen -------------------------------------


## Kennung eines Bauteils als Ort ("b<id>").
static func place_id_of(b: SimBuilding) -> String:
	return "b%d" % b.id


## Leichen verrotten samt Inventar nach corpse_rot_hours (Senke); Wölfe räumt der Nachschub auf.
func _update_corpses() -> void:
	var rot_after := data.balf("combat.corpse_rot_hours") * 3600.0
	for id: int in characters.keys():
		var c: SimCharacter = characters[id]
		if c.dead and (c.kind != SimCharacter.Kind.WOLF or c.boss) and time - c.death_time >= rot_after:  # Menschen, Karawane, Leitwolf
			characters.erase(id)
			events.append({"type": "corpse_rotted", "id": id, "owner": c.owner_id, "name": c.name})


## Orte aus Bauteilen (Sensoren, Anker, Handelstische) an alle Charaktere des Besitzers verteilen.
## Orte für einen Besitzer und alle Gildenmitglieder neu aufbauen (Gildenbauteile sind gemeinsame Orte).
func refresh_places(owner_id: String) -> void:
	var owners := {owner_id: true}
	for member: String in guilds.members_of(owner_id):
		owners[member] = true
	for owner: String in owners:
		_refresh_places_one(owner)


func _refresh_places_one(owner_id: String) -> void:
	var places := {}
	var tables := 0
	for b: SimBuilding in map.buildings.values():
		if SimTrade.is_depot(self, b):
			places[place_id_of(b)] = {"name": b.label, "pos": b.center()}
			continue
		if not allied(b.owner_id, owner_id):
			continue
		# Bauteile der Gildenmitglieder sind Orte mit Besitzerzusatz ("Anker (Ben)")
		var suffix := "" if b.owner_id == owner_id else " (%s)" % b.owner_id
		if SimDefense.is_sensor(self, b):
			places[place_id_of(b)] = {"name": b.label + suffix, "pos": b.center()}
		elif b.part == "anchor":
			places[place_id_of(b)] = {"name": "Anker" + suffix, "pos": b.center()}
		elif SimTrade.is_trade_table(self, b):
			if b.owner_id == owner_id:
				tables += 1
			places[place_id_of(b)] = {"name": ("Handelstisch %d" % tables if b.owner_id == owner_id else "Handelstisch") + suffix, "pos": b.center()}
		elif SimDefense.is_turret(self, b):
			places[place_id_of(b)] = {"name": b.label + suffix, "pos": b.center()}
	for c: SimCharacter in characters.values():
		if c.owner_id != owner_id:
			continue
		c.extra_places = places.duplicate(true)
		_resolve_symbolic_places(c)


## Symbolische Orte (SimData.SYMBOLIC_PLACES) aus Sicht dieses Charakters: eigener Anker, nächster eigener (oder
## verbündeter) Handelstisch, nächstes Depot – gemessen ab der Ausloggen-Position, live ab dem Standort.
func _resolve_symbolic_places(c: SimCharacter) -> void:
	var from := c.logout_pos if c.control == SimCharacter.Controller.RULES else c.pos
	var claim := claims.claim_of_owner(c.owner_id)
	if claim != null and claim.anchor_building_id >= 0 and map.buildings.has(claim.anchor_building_id):
		var anchor: SimBuilding = map.buildings[claim.anchor_building_id]
		c.extra_places["own_anchor"] = {"name": SimData.SYMBOLIC_PLACES["own_anchor"]["name"], "pos": anchor.center()}
	var table: SimBuilding = null
	var depot: SimBuilding = null
	var market: SimBuilding = null  # Depot in einer kampffreien Zone: der sichere Lieferort
	for b: SimBuilding in map.buildings.values():
		if SimTrade.is_depot(self, b):
			if depot == null or b.center().distance_squared_to(from) < depot.center().distance_squared_to(from):
				depot = b
			if in_peace_zone(b.center()) and (market == null or b.center().distance_squared_to(from) < market.center().distance_squared_to(from)):
				market = b
		elif SimTrade.is_trade_table(self, b) and allied(b.owner_id, c.owner_id):
			if table == null or b.center().distance_squared_to(from) < table.center().distance_squared_to(from):
				table = b
	if table != null:
		c.extra_places["own_table"] = {"name": SimData.SYMBOLIC_PLACES["own_table"]["name"], "pos": table.center()}
	if depot != null:
		c.extra_places["nearest_depot"] = {"name": SimData.SYMBOLIC_PLACES["nearest_depot"]["name"], "pos": depot.center()}
	if market != null:
		c.extra_places["nearest_market"] = {"name": SimData.SYMBOLIC_PLACES["nearest_market"]["name"], "pos": market.center()}


# --- Neutraler Markt und Depot --------------------------------------------


## Zonendefinition aus balance.json (leer, wenn keine Zone).
func zone_def(zone: String) -> Dictionary:
	return data.balance.get("zones", {}).get(zone, {}) if not zone.is_empty() else {}


func zone_at(pos: Vector2) -> Dictionary:
	return zone_def(map.zone(SimMap.cell_of(pos)))


## Marktboden (neutraler Markt).
func in_market(pos: Vector2) -> bool:
	return map.zone(SimMap.cell_of(pos)) == "market"


## Kampffreie Zone: kein Schaden, Projektile verpuffen, Wölfe und Turrets lassen die Leute in Ruhe.
func in_peace_zone(pos: Vector2) -> bool:
	return bool(zone_at(pos).get("peace", false))


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
		if lod_enabled and c.control != SimCharacter.Controller.PLAYER and dt < coarse_dt and not _needs_fine_step(c) and not _near_online(c, lod_radius):
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
			SimCharacter.Controller.CARAVAN_AI:
				intent = CaravanAI.decide(self, c, step_dt)
		_apply_intent(c, intent if intent != null else SimIntent.new(), step_dt)
	_intents.clear()
	spatial.rebuild(characters)
	SimCombat.update_projectiles(self, dt)
	_update_hunger(dt)
	_update_nodes(dt)
	SimConstruction.update_decay(self, dt)
	SimDefense.update_sensors_and_traps(self, dt)
	SimDefense.update_turrets(self, dt)
	SimDefense.update_bombs(self)
	_update_corpses()
	claims.update(self, dt)
	_update_wolves(dt)
	SimEvents.update(self)
	SimEvents.update_caravans(self)


## Ist ein lebender Online-Spieler (vom Spieler gesteuert oder beobachtet) in Reichweite?
## Kämpfende laufen immer fein (Design: "fein bei Kampf"), auch ohne Zuschauer – sonst entscheidet die grobe Stufe
## das Duell (ein Schuss je Sekunde, veraltete Ziele). Billig: kein Raster, nur Zustand.
func _needs_fine_step(c: SimCharacter) -> bool:
	if c.kind == SimCharacter.Kind.WOLF:
		return c.ai_state != WolfAI.STATE_WANDER
	if SimSensors.is_under_attack(self, c):
		return true
	if c.active_rule_index >= 0 and c.active_rule_index < c.rules.size():
		var action := String(c.rules[c.active_rule_index]["then"]["action"])
		return action == "fight_back" or action == "attack" or (action == "toll" and bool(c.action_state.get("toll_active", false)))
	return false


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
		var speed := c.move_speed * (1.0 - c.armor_slow) * (1.0 - (SimEffects.effect_slow(self, c) if not c.effects.is_empty() else 0.0))
		if c.is_weakened():
			speed *= data.balf("character.weakened_speed_multiplier")
		c.pos = map.resolve_move(c.pos, move * speed * dt, c.collision_radius, c.owner_id, data)
		if c.hidden:
			reveal(c)

	if intent.interact:
		if not _loot(c) and not _deposit_at_anchor(c) and not _load_turret_near(c) and not SimToll.pay_toll(self, c):
			_gather(c, dt, intent.gather_cell)
	else:
		c.gather_progress = 0.0
		c.gather_target = Vector2i(-1, -1)

	if intent.eat:
		eat(c)
	if intent.shoot:
		SimCombat.attack(self, c)
	if intent.melee:
		SimCombat.melee(self, c)
	SimCrafting.update_healing(self, c, intent, dt)
	_update_hiding(c, intent, dt)
	SimEffects.update_effects(self, c, dt)

	c.fire_cooldown = maxf(0.0, c.fire_cooldown - dt)
	c.bite_cooldown = maxf(0.0, c.bite_cooldown - dt)


func _gather(c: SimCharacter, dt: float, wanted_cell: Vector2i = Vector2i(-1, -1)) -> void:
	var reach := data.balf("character.interact_range")
	var node: SimResourceNode = null
	if wanted_cell.x >= 0:
		node = map.node_at(wanted_cell)
		if node != null and (node.amount <= 0 or node.center().distance_to(c.pos) > reach):
			node = null
	if node == null:
		node = map.nearest_node(c.pos, reach, "", true)
	# Offline-Charaktere sammeln nie auf fremdem Land (Rohstoffknoten nur für Eigentümer-NPCs)
	if node != null and c.control == SimCharacter.Controller.RULES and claims.is_foreign(node.cell, c.owner_id):
		node = null
	if node != null and c.control == SimCharacter.Controller.RULES and not node_offline_ok(node, c.owner_id):
		node = null
	if node != null and c.control != SimCharacter.Controller.PLAYER and node_live_only(node):
		node = null
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
		var claim := claims.claim_at(node.cell)
		if claim != null and not allied(claim.owner_id, c.owner_id):
			events.append({"type": "theft", "id": c.id, "claim": claim.id, "owner": claim.owner_id, "resource": node.resource})


## Quelle nur live abbaubar (Schwefel)?
func node_live_only(node: SimResourceNode) -> bool:
	return bool(data.tiles.get(map.tile_id(node.cell), {}).get("live_only", false))


## Darf ein Offline-Charakter dieses Besitzers die Quelle abbauen? Eisen/Kohle nur mit eigener Mine direkt daneben.
func node_offline_ok(node: SimResourceNode, owner_id: String) -> bool:
	var needs := String(data.tiles.get(map.tile_id(node.cell), {}).get("offline_needs", ""))
	if needs.is_empty():
		return true
	for step: Vector2i in SimMap.NEIGHBORS_4:
		var neighbor := node.cell + step
		if not map.tile_built(neighbor):
			continue
		var b := map.building_at_half(neighbor * 2)
		if b != null and b.part == needs and allied(b.owner_id, owner_id):
			return true
	return false


## Kugeln ins eigene Turret laden (E daneben). true, wenn etwas geladen wurde.
func _load_turret_near(c: SimCharacter) -> bool:
	if c.control != SimCharacter.Controller.PLAYER:
		return false
	var b := SimDefense.turret_near(self, c)
	if b == null:
		return false
	var ammo := String(data.buildings[b.part]["turret"]["ammo"])
	return SimDefense.turret_load(self, c, b, int(c.inventory.get(ammo, 0))) > 0


## Holz am eigenen Anker abliefern (E daneben). true, wenn etwas abgeliefert wurde.
func _deposit_at_anchor(c: SimCharacter) -> bool:
	if c.control != SimCharacter.Controller.PLAYER or int(c.inventory.get("wood", 0)) <= 0:
		return false
	var claim := claims.claim_of_owner(c.owner_id)
	if claim == null or claim.anchor_building_id < 0:
		return false
	var anchor: SimBuilding = map.buildings.get(claim.anchor_building_id)
	if anchor == null or anchor.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return false
	return claims.deposit(self, c, claim, int(c.inventory["wood"])) > 0


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
					c.durability[item_id] = other.durability.get(item_id, {"left": float(data.items[item_id]["durability"]), "max": float(data.items[item_id]["durability"])})
					other.durability.erase(item_id)
					items_taken.append(item_id)
		if taken.is_empty() and items_taken.is_empty():
			continue
		SimCrafting.refresh_equipment(self, c)
		SimCrafting.refresh_equipment(self, other)
		events.append({"type": "loot", "id": c.id, "from": other.id, "items": taken, "equipment": items_taken})
		return true
	return false


## Isst ein essbares Stück. Gibt das Ereignis zurück (leer, wenn nichts gegessen wurde).
func eat(c: SimCharacter) -> Dictionary:
	var hunger_max := data.balf("hunger.max")
	if c.hunger >= hunger_max:
		return {}
	var best := ""
	for candidate: String in data.resource_order:
		var cdef: Dictionary = data.resources[candidate]
		if cdef.get("edible", false) and int(c.inventory.get(candidate, 0)) > 0 and (best.is_empty() or float(cdef["nutrition"]) > float(data.resources[best]["nutrition"])):
			best = candidate
	for rid: String in ([best] if not best.is_empty() else []):
		var def: Dictionary = data.resources[rid]
		var before := int(c.inventory[rid])
		c.inventory[rid] = before - 1
		c.hunger = minf(hunger_max, c.hunger + float(def["nutrition"]))
		var event := {"type": "eat", "id": c.id, "resource": rid, "before": before, "after": before - 1}
		events.append(event)
		return event
	return {}


# --- Namen und Sichtbarkeit ----------------------------------------------


## Verbündet: derselbe Besitzer oder dieselbe Gilde.
func allied(a: String, b: String) -> bool:
	return guilds.allied(a, b)


## Gildenbefehl eines Besitzers: gründen <Name>, einladen <Spielername>, annehmen, verlassen. Rückgabe: Meldung.
func guild_command(owner_id: String, op: String, arg: String) -> String:
	var text := _guild_command(owner_id, op, arg)
	# Orte der Beteiligten neu aufbauen (Gildenbauteile kommen dazu oder fallen weg)
	var owners := {owner_id: true}
	for member: String in guilds.members_of(owner_id):
		owners[member] = true
	for c: SimCharacter in characters.values():
		if c.kind == SimCharacter.Kind.PLAYER and (owners.has(c.owner_id) or c.owner_id == arg.strip_edges()):
			owners[c.owner_id] = true
	for owner: String in owners:
		refresh_places(owner)
	return text


func guild_level(owner_id: String) -> int:
	return guilds.level_of(owner_id, data.bali("guild.xp_per_level"), data.bali("guild.max_level"))


func _guild_command(owner_id: String, op: String, arg: String) -> String:
	match op:
		"found":
			var reason := guilds.found(owner_id, arg)
			return ("Gilde „%s“ gegründet." % arg.strip_edges()) if reason.is_empty() else "Gilde: %s" % reason
		"invite":
			var target := arg.strip_edges()
			var known := false
			for c: SimCharacter in characters.values():
				if c.kind == SimCharacter.Kind.PLAYER and c.owner_id == target:
					known = true
			if not known:
				return "Gilde: Spieler „%s“ ist unbekannt" % target
			var reason := guilds.invite(owner_id, target)
			return ("%s eingeladen (er antwortet mit /gilde annehmen)." % target) if reason.is_empty() else "Gilde: %s" % reason
		"accept":
			var reason := guilds.accept(owner_id)
			return ("Willkommen in der Gilde „%s“." % guilds.name_of(owner_id)) if reason.is_empty() else "Gilde: %s" % reason
		"leave":
			var name := guilds.name_of(owner_id)
			var reason := guilds.leave(owner_id)
			return ("Du hast „%s“ verlassen." % name) if reason.is_empty() else "Gilde: %s" % reason
	return "Gilde: unbekannter Befehl (gründen <Name>, einladen <Spieler>, annehmen, verlassen)"


## Client-Spiegel: Name der Gilde, die einen gerade einlädt (aus dem Selbstblock).
var guild_invite_name: String = ""


# --- Briefe ---------------------------------------------------------------


var letters: Dictionary = {}  # Empfänger (owner_id) -> [{from, text, time}]; liegen, bis der Empfänger sie abholt


## Kennt die Welt diesen Besitzer (irgendein Charakter, auch tot, oder Gildenmitglied)?
func knows_owner(owner_id: String) -> bool:
	if guilds.guild_of(owner_id) >= 0 or letters.has(owner_id):
		return true
	for c: SimCharacter in characters.values():
		if c.kind == SimCharacter.Kind.PLAYER and c.owner_id == owner_id:
			return true
	return false


## Brief hinterlegen. Rückgabe: Grund oder leer.
func send_letter(from_owner: String, to_owner: String, text: String) -> String:
	to_owner = to_owner.strip_edges()
	text = text.strip_edges().substr(0, data.bali("letters.max_length"))
	if to_owner.is_empty() or text.is_empty():
		return "Empfänger und Text nötig"
	if to_owner == from_owner:
		return "an dich selbst?"
	if not knows_owner(to_owner):
		return "Empfänger „%s“ unbekannt" % to_owner
	if not letters.has(to_owner):
		letters[to_owner] = []
	letters[to_owner].append({"from": from_owner, "text": text, "time": time})
	events.append({"type": "letter", "from": from_owner, "to": to_owner})
	return ""


## Briefe eines Empfängers abholen (werden dabei entfernt).
func take_letters(owner_id: String) -> Array:
	var result: Array = letters.get(owner_id, [])
	letters.erase(owner_id)
	return result


## Kennt `observer` den Namen von `other`? Eigene Leute und Tiere immer, fremde Menschen nur in unmittelbarer Nähe.
func knows_name(observer: SimCharacter, other: SimCharacter) -> bool:
	if observer == null or other == null or observer == other:
		return true
	if other.kind != SimCharacter.Kind.PLAYER or allied(other.owner_id, observer.owner_id):
		return true
	return observer.pos.distance_to(other.pos) <= data.balf("combat.name_range")


## Wie `observer` den anderen benennt: Name oder "Unbekannter mit <Waffe>" (Chronik-Design).
func describe(observer: SimCharacter, other: SimCharacter) -> String:
	if other == null:
		return "Unbekannt"
	if knows_name(observer, other):
		return other.name
	var weapon := String(data.items.get(other.active_weapon, {}).get("name", ""))
	return "Unbekannter mit %s" % (weapon if not weapon.is_empty() else "bloßen Händen")


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
		if not c.effects.is_empty():
			rate *= SimEffects.effect_hunger_multiplier(self, c)
		c.hunger = maxf(0.0, c.hunger - rate * dt)
		# Krankheit als Ereignis: trifft zufällig, live wie offline
		if rng.randf() < data.balf("effects.sick.chance_per_hour") * dt / 3600.0:
			SimEffects.apply_effect(self, c, "sick", -1)


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
			if other != c and not other.dead and not allied(other.owner_id, c.owner_id) and other.pos.distance_squared_to(c.pos) <= reveal_radius_sq:
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
			if c.kind == SimCharacter.Kind.WOLF and c.dead and not c.boss:  # die Leiche des Leitwolfs bleibt als Beute liegen
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
		if SimSensors.is_under_attack(self, c) or SimCombat.nearest_enemy(self, c, radius) != null:
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
