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

var unlocks_by_owner: Dictionary = {}    # Besitzer -> {fact: true}: freigeschaltete Regel-Bausteine (todesfest)
var claims := SimClaims.new()            # Land: Anker, Kacheln, Unterhalt
var guilds := SimGuilds.new()            # Gilden: Verbündete teilen Claims, Türen und Alarm

var _next_id: int = 1
var _next_building_id: int = 1
var _intents: Dictionary = {}            # id -> SimIntent, gilt nur für den nächsten Tick
var _wolf_respawn_timer: float = 0.0


func _init(p_data: SimData, seed: int = 12345) -> void:
	data = p_data
	map = SimMap.new(data)
	map.guilds = guilds
	claims.guilds = guilds
	tick_dt = 1.0 / data.balf("tick_rate")
	rng.seed = seed


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
	for other: SimBuilding in depots():
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
	if not owner_id.is_empty() and (is_sensor(b) or is_container(b)):
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
	refresh_equipment(c)
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
	c.inventory["meat"] = data.bali("wolf.meat") if data.balance.get("wolf", {}).has("meat") else 2
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


# --- Freischaltungen ------------------------------------------------------

func unlocks_of(owner_id: String) -> Dictionary:
	return unlocks_by_owner.get(owner_id, {})


## Schaltet einen Baustein-Grundstein für einen Besitzer frei (einmalig) und meldet es.
func unlock(owner_id: String, fact: String, witness: SimCharacter = null) -> bool:
	if not unlocks_by_owner.has(owner_id):
		unlocks_by_owner[owner_id] = {}
	if unlocks_by_owner[owner_id].has(fact):
		return false
	unlocks_by_owner[owner_id][fact] = true
	var labels: PackedStringArray = []
	for id: String in data.action_order:
		if data.unlock_of(data.actions[id]).get("fact", "") == fact:
			labels.append(data.format_template(String(data.actions[id]["label"]), data.actions[id]["params"], {}))
	for id: String in data.condition_order:
		if data.unlock_of(data.conditions[id]).get("fact", "") == fact:
			labels.append(String(data.conditions[id]["label"]))
	var label := ", ".join(labels) if not labels.is_empty() else fact
	events.append({"type": "unlock", "id": witness.id if witness != null else -1, "owner": owner_id, "fact": fact, "label": label})
	if witness != null and witness.control == SimCharacter.Controller.RULES:
		SimChronicle.add(self, witness, "neuer Regel-Baustein freigeschaltet: %s" % label)
	return true


## Ist ein Baustein für den Besitzer dieses Charakters nutzbar?
func can_use(c: SimCharacter, def: Dictionary) -> bool:
	return data.is_unlocked(def, unlocks_of(c.owner_id))


# --- Ausrüstung -----------------------------------------------------------

## Leitet Rüstung und Nahkampfwerte aus der getragenen Rüstung und der aktiven Waffe ab (nur Spielercharaktere).
## Rüstung zählt nur, wenn sie angelegt ist (equip_armor); besitzen allein schützt nicht.
func refresh_equipment(c: SimCharacter) -> void:
	if c.kind != SimCharacter.Kind.PLAYER:
		return
	if not c.worn_armor.is_empty() and (not c.items.has(c.worn_armor) or data.items.get(c.worn_armor, {}).get("kind", "") != "armor"):
		c.worn_armor = ""  # zerbrochen, geplündert oder unbekannt
	var worn: Dictionary = data.items.get(c.worn_armor, {})
	c.armor = data.balf("character.armor") + float(worn.get("armor", 0.0))
	c.armor_slow = float(worn.get("slow", 0.0))  # schwere Rüstung verlangsamt, solange sie getragen wird
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
		c.melee_effect = String(weapon.get("effect", ""))
	else:
		c.melee_damage = 0.0
		c.melee_effect = ""


## Herstellen: baut einen Gegenstand (Ausrüstung) oder ein Verbrauchsgut (Rohstoff mit 'cost'). Braucht der Eintrag
## eine Station ('needs_building': Werkbank, Schmelzofen, Schmiede, Lagerfeuer), muss sie in Reichweite stehen.
## Rückgabe: leer = gebaut, sonst der Grund.
func craft(c: SimCharacter, item_id: String) -> String:
	if data.resources.has(item_id) and data.resources[item_id].has("cost"):
		return _craft_consumable(c, item_id)
	var def: Dictionary = data.items.get(item_id, {})
	if def.is_empty():
		return "unbekannter Gegenstand"
	if c.items.has(item_id):
		return "schon vorhanden"
	var cost: Dictionary = def.get("cost", {})
	if cost.is_empty():
		return "nicht baubar"
	var station := station_reason(c, item_id)
	if not station.is_empty():
		return station
	for rid: String in cost:
		var needed := int(cost[rid])
		if int(c.inventory.get(rid, 0)) < needed:
			return "zu wenig %s (%d nötig)" % [data.resources[rid]["name"], needed]
	for rid: String in cost:
		c.inventory[rid] = int(c.inventory[rid]) - int(cost[rid])
	c.items.append(item_id)
	c.durability[item_id] = {"left": float(def["durability"]), "max": float(def["durability"])}
	refresh_equipment(c)
	events.append({"type": "craft", "id": c.id, "item": item_id})
	return ""


# --- Verschleiß und Reparatur ---------------------------------------------

func durability_left(c: SimCharacter, item_id: String) -> float:
	return float(c.durability.get(item_id, {}).get("left", 0.0))


func durability_max(c: SimCharacter, item_id: String) -> float:
	return float(c.durability.get(item_id, {}).get("max", 0.0))


## Reparaturkosten: Anteil der Baukosten, aufgerundet. Leer = nicht reparierbar.
func repair_cost(item_id: String) -> Dictionary:
	var cost: Dictionary = data.items.get(item_id, {}).get("cost", {})
	var result := {}
	for rid: String in cost:
		result[rid] = int(ceilf(float(cost[rid]) * data.balf("wear.repair_cost_fraction")))
	return result


## Warum die Werkbank einen Gegenstand nicht reparieren kann; leer = möglich.
func repair_reason(c: SimCharacter, item_id: String) -> String:
	if not c.items.has(item_id):
		return "nicht vorhanden"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	var cost := repair_cost(item_id)
	if cost.is_empty():
		return "nicht reparierbar"
	var station := station_reason(c, item_id)
	if not station.is_empty():
		return station
	var left := durability_left(c, item_id)
	var current_max := durability_max(c, item_id)
	if left >= current_max - 0.001:
		return "nicht abgenutzt"
	var next_max := current_max - float(data.items[item_id]["durability"]) * data.balf("wear.repair_max_loss")
	if next_max < 1.0:
		return "zu abgenutzt, nicht mehr reparierbar"
	for rid: String in cost:
		if int(c.inventory.get(rid, 0)) < int(cost[rid]):
			return "zu wenig %s (%d nötig)" % [data.resources[rid]["name"], int(cost[rid])]
	return ""


## Repariert an der Werkbank: zurück auf das gesunkene Maximum (nie wieder 100 %). Rückgabe: Grund oder leer.
func repair(c: SimCharacter, item_id: String) -> String:
	var reason := repair_reason(c, item_id)
	if not reason.is_empty():
		return reason
	var cost := repair_cost(item_id)
	for rid: String in cost:
		c.inventory[rid] = int(c.inventory[rid]) - int(cost[rid])
	var next_max := durability_max(c, item_id) - float(data.items[item_id]["durability"]) * data.balf("wear.repair_max_loss")
	c.durability[item_id] = {"left": next_max, "max": next_max}
	events.append({"type": "repair", "id": c.id, "item": item_id, "max": next_max})
	return ""


## Eine Nutzung abziehen; bei 0 zerbricht der Gegenstand (Ereignis, Chronik für Offline-Charaktere).
func wear(c: SimCharacter, item_id: String, amount: float = 1.0) -> void:
	if not c.items.has(item_id):
		return
	if not c.durability.has(item_id):
		c.durability[item_id] = {"left": float(data.items[item_id]["durability"]), "max": float(data.items[item_id]["durability"])}
	var entry: Dictionary = c.durability[item_id]
	entry["left"] = float(entry["left"]) - amount
	if float(entry["left"]) > 0.0:
		return
	c.items.erase(item_id)
	c.durability.erase(item_id)
	refresh_equipment(c)
	events.append({"type": "item_broken", "id": c.id, "item": item_id})
	if c.kind == SimCharacter.Kind.PLAYER and c.control == SimCharacter.Controller.RULES:
		SimChronicle.add(self, c, "%s zerbrochen" % data.items[item_id]["name"])


## Getragene Rüstung (Kennung) oder leer.
func armor_item_of(c: SimCharacter) -> String:
	return c.worn_armor if c.items.has(c.worn_armor) else ""


## Rüstung anlegen (leer = ablegen). Explizit, nie automatisch: der Spieler entscheidet, was er trägt
## (Design: schwere Rüstung verlangsamt, Gegenmittel ist Ablegen). Rückgabe: Grund oder leer.
func equip_armor(c: SimCharacter, item_id: String) -> String:
	if c.dead:
		return "tot"
	if not item_id.is_empty():
		if not c.items.has(item_id):
			return "nicht vorhanden"
		if data.items.get(item_id, {}).get("kind", "") != "armor":
			return "keine Rüstung"
		if c.worn_armor == item_id:
			return "schon angelegt"
	elif c.worn_armor.is_empty():
		return "nichts angelegt"
	c.worn_armor = item_id
	refresh_equipment(c)
	events.append({"type": "equip", "id": c.id, "item": item_id})
	return ""


## Besessene Rüstungen (Kennungen), in Datenreihenfolge.
func owned_armors(c: SimCharacter) -> Array[String]:
	var result: Array[String] = []
	for item_id: String in data.item_order:
		if c.items.has(item_id) and data.items[item_id].get("kind", "") == "armor":
			result.append(item_id)
	return result


func _craft_consumable(c: SimCharacter, rid: String) -> String:
	var def: Dictionary = data.resources[rid]
	var cost: Dictionary = def["cost"]
	var station := station_reason(c, rid)
	if not station.is_empty():
		return station
	for need: String in cost:
		if int(c.inventory.get(need, 0)) < int(cost[need]):
			return "zu wenig %s (%d nötig)" % [data.resources[need]["name"], int(cost[need])]
	var produced := int(def.get("yield", 1))
	if c.inventory_count() - _cost_total(cost) + produced > data.bali("inventory.capacity"):
		return "Inventar voll"
	for need: String in cost:
		c.inventory[need] = int(c.inventory[need]) - int(cost[need])
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + produced
	if def.has("heal"):
		unlock(c.owner_id, "owned_bandage", c)
	if def.get("cures", []).has("poison"):
		unlock(c.owner_id, "owned_antidote", c)
	if def.get("cures", []).has("sick"):
		unlock(c.owner_id, "owned_medicine", c)
	if c.control == SimCharacter.Controller.PLAYER:
		unlock(c.owner_id, "crafted_consumable", c)
	events.append({"type": "craft", "id": c.id, "item": rid})
	return ""


## Warum ein Verbrauchsgut gerade nicht herstellbar ist (für NPC-Regeln); leer = möglich.
## ignore_station: die Station prüft der Aufrufer selbst (der NPC läuft erst hin).
func craft_reason(c: SimCharacter, rid: String, ignore_station: bool = false) -> String:
	if not data.resources.has(rid) or not data.resources[rid].has("cost"):
		return "kein herstellbares Verbrauchsgut"
	var cost: Dictionary = data.resources[rid]["cost"]
	if not ignore_station:
		var station := station_reason(c, rid)
		if not station.is_empty():
			return station
	for need: String in cost:
		if int(c.inventory.get(need, 0)) < int(cost[need]):
			return "zu wenig %s (%d nötig)" % [data.resources[need]["name"], int(cost[need])]
	if c.inventory_count() - _cost_total(cost) + int(data.resources[rid].get("yield", 1)) > data.bali("inventory.capacity"):
		return "Inventar voll"
	return ""


## Nächstes Bauteil einer Art (beliebiger Besitzer) in Interaktionsreichweite, sonst null.
func building_part_near(c: SimCharacter, part: String) -> SimBuilding:
	var reach := data.balf("character.interact_range") + 0.5
	for b: SimBuilding in map.buildings.values():
		if b.part == part and b.center().distance_to(c.pos) <= reach:
			return b
	return null


## Warum die Station eines Gegenstands/Verbrauchsguts fehlt ("Werkbank nicht in Reichweite"); leer = von Hand oder Station da.
func station_reason(c: SimCharacter, item_id: String) -> String:
	var needs := data.station_of(item_id)
	if needs.is_empty() or building_part_near(c, needs) != null:
		return ""
	return "%s nicht in Reichweite" % data.buildings[needs]["name"]


## Nächste Station einer Art (beliebiger Besitzer) innerhalb der Leine eines NPC, sonst null. Ohne Leine: überall.
func station_in_leash(c: SimCharacter, part: String) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := INF
	for b: SimBuilding in map.buildings.values():
		if b.part != part:
			continue
		if c.leash_radius > 0.0 and b.center().distance_to(c.leash_center) > c.leash_radius + 0.5:
			continue
		var d := b.center().distance_squared_to(c.pos)
		if d < best_d:
			best_d = d
			best = b
	return best


## Munition einer Waffe (Kennung des Verbrauchsguts) oder leer, wenn sie keine braucht.
func ammo_of(weapon_id: String) -> String:
	return String(data.items.get(weapon_id, {}).get("ammo", ""))


## Kann mit dieser Waffe geschossen werden? (Keine Munition nötig oder Munition dabei.)
func has_ammo(c: SimCharacter, weapon_id: String) -> bool:
	var ammo := ammo_of(weapon_id)
	return ammo.is_empty() or int(c.inventory.get(ammo, 0)) > 0


static func _cost_total(cost: Dictionary) -> int:
	var total := 0
	for amount: Variant in cost.values():
		total += int(amount)
	return total


## Passendstes Heilmittel im Inventar: erst eines, das einen laufenden Effekt kuriert, sonst das stärkste,
## wenn Leben fehlt. Leer, wenn nichts hilft.
func heal_item_of(c: SimCharacter) -> String:
	var best := ""
	var best_heal := -1.0
	for rid: String in data.resource_order:
		var def: Dictionary = data.resources[rid]
		if not def.has("heal") or int(c.inventory.get(rid, 0)) <= 0:
			continue
		for effect: String in def.get("cures", []):
			if has_effect(c, effect):
				return rid
		if c.hp < c.max_hp and float(def["heal"]) > best_heal and float(def["heal"]) > 0.0:
			best_heal = float(def["heal"])
			best = rid
	return best


## Heilung = Kanalisierung: heal_time Sekunden ohne Angriff (Laufen erlaubt), dann +heal Leben, Verband weg.
func _update_healing(c: SimCharacter, intent: SimIntent, dt: float) -> void:
	if not intent.heal or intent.shoot or intent.melee:
		c.heal_progress = 0.0
		return
	var rid := heal_item_of(c)
	if rid.is_empty():
		c.heal_progress = 0.0
		return
	var def: Dictionary = data.resources[rid]
	c.heal_progress += dt
	if c.heal_progress + 0.0001 >= float(def["heal_time"]):
		c.heal_progress = 0.0
		var before := c.hp
		c.hp = minf(c.max_hp, c.hp + float(def["heal"]))
		c.inventory[rid] = int(c.inventory[rid]) - 1
		var cured: Array[String] = []
		for effect: String in def.get("cures", []):
			if c.effects.erase(effect):
				cured.append(effect)
		events.append({"type": "healed", "id": c.id, "amount": c.hp - before, "resource": rid, "left": int(c.inventory[rid]), "cured": cured})


# --- Zustandseffekte ------------------------------------------------------

func has_effect(c: SimCharacter, effect: String) -> bool:
	return float(c.effects.get(effect, -1e9)) > time


const EFFECT_NAMES: Dictionary = {"bleeding": "blutet", "poison": "vergiftet", "sick": "erkrankt"}


## Verlangsamung durch laufende Effekte (Krankheit), zusätzlich zur Rüstung.
func effect_slow(c: SimCharacter) -> float:
	var slow := 0.0
	for effect: String in c.effects:
		if has_effect(c, effect):
			slow = maxf(slow, float(data.balance["effects"][effect].get("slow", 0.0)))
	return slow


func effect_hunger_multiplier(c: SimCharacter) -> float:
	var factor := 1.0
	for effect: String in c.effects:
		if has_effect(c, effect):
			factor *= float(data.balance["effects"][effect].get("hunger_multiplier", 1.0))
	return factor


## Effekt anlegen oder verlängern; ignoriert Rüstung. Ereignis und Chronik nur beim Beginn.
func apply_effect(c: SimCharacter, effect: String, attacker_id: int) -> void:
	if c.dead or not data.balance.get("effects", {}).has(effect):
		return
	var fresh := not has_effect(c, effect)
	c.effects[effect] = time + data.balf("effects.%s.duration" % effect)
	if not fresh:
		return
	events.append({"type": "effect", "id": c.id, "effect": effect, "attacker": attacker_id})
	if c.kind == SimCharacter.Kind.PLAYER and c.control == SimCharacter.Controller.RULES:
		SimChronicle.add(self, c, String(EFFECT_NAMES.get(effect, effect)))


## Laufende Effekte: Blutung zieht Leben ohne Rüstung ab und kann töten ("verblutet").
func _update_effects(c: SimCharacter, dt: float) -> void:
	var zone_effect := String(zone_at(c.pos).get("effect", ""))
	if not zone_effect.is_empty():
		apply_effect(c, zone_effect, -1)  # Sumpf: solange man drin steht
	if c.effects.is_empty():
		return
	for effect: String in c.effects.keys():
		if float(c.effects[effect]) <= time:
			c.effects.erase(effect)
			events.append({"type": "effect_ended", "id": c.id, "effect": effect})
			continue
		var dps := data.balf("effects.%s.damage_per_second" % effect)
		if dps > 0.0:
			c.hp = maxf(0.0, c.hp - dps * dt)
			if c.hp <= 0.0:
				_kill(c, c.last_attacker_id, "verblutet" if effect == "bleeding" else "an Gift gestorben")
				return


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


# --- Bauen ----------------------------------------------------------------

## Warum ein Bauteil hier nicht gesetzt werden kann; leer = möglich.
func can_place(c: SimCharacter, part_id: String, origin: Vector2i, rotation: int) -> String:
	var def: Dictionary = data.buildings.get(part_id, {})
	if def.is_empty():
		return "unbekanntes Bauteil"
	if not bool(def.get("placeable", true)):
		return "nicht baubar"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live baubar"
	var cells := SimBuilding.cells_for(def["size"], origin, rotation)
	var center := Vector2.ZERO
	for half: Vector2i in cells:
		var tile := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
		if not map.is_walkable(tile):
			return "kein freier Boden"
		if not map.zone(tile).is_empty():
			return String(zone_def(map.zone(tile)).get("build_reason", "hier wird nicht gebaut"))
		if map.built_half.has(half):
			return "schon bebaut"
		center += SimBuilding.half_cell_center(half)
	center /= cells.size()
	if center.distance_to(c.pos) > data.balf("building.reach"):
		return "zu weit weg"
	for other: SimCharacter in characters.values():
		if String(def["passable"]) == "all":
			break  # begehbare Teile (Sensor, Falle, Sprengsatz) dürfen unter Füßen liegen
		if other.dead or other.pos.distance_squared_to(center) > 16.0:
			continue
		for half: Vector2i in cells:
			var closest := Vector2(clampf(other.pos.x, half.x * 0.5, half.x * 0.5 + 0.5), clampf(other.pos.y, half.y * 0.5, half.y * 0.5 + 0.5))
			if closest.distance_to(other.pos) < other.collision_radius:
				return "jemand steht im Weg"
	for rid: String in def["cost"]:
		if int(c.inventory.get(rid, 0)) < int(def["cost"][rid]):
			return "zu wenig %s (%d nötig)" % [data.resources[rid]["name"], int(def["cost"][rid])]
	# Land: nur Eigentümer bauen auf einem Claim; Anker haben eigene Regeln
	var anchor_tile := SimMap.cell_of(center)
	if part_id == "anchor":
		var reason := claims.anchor_reason(data, c, anchor_tile)
		if not reason.is_empty():
			return reason
	if bool(def.get("one_per_owner", false)):
		for b: SimBuilding in map.buildings.values():
			if b.owner_id == c.owner_id and b.part == part_id:
				return "du hast schon %s" % [def["name"]]
	if def.has("next_to_resource"):
		var wanted: Array = def["next_to_resource"]
		var adjacent := false
		for half: Vector2i in cells:
			var tile := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
			for step: Vector2i in SimMap.NEIGHBORS_4:
				var node := map.node_at(tile + step)
				if node != null and wanted.has(node.resource):
					adjacent = true
		if not adjacent:
			var names: PackedStringArray = []
			for rid: String in wanted:
				names.append(String(data.resources[rid]["name"]))
			return "muss neben %s stehen" % " oder ".join(names)
	for half: Vector2i in cells:
		var tile := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
		if claims.is_foreign(tile, c.owner_id) and not bool(def.get("anywhere", false)):
			return "fremder Claim"
		if bool(def.get("claim_only", false)):
			var own := claims.claim_at(tile)
			if own == null or own.owner_id != c.owner_id:
				return "nur im eigenen Claim"
	return ""


## Setzt ein Bauteil (nur live). null, wenn nicht möglich.
func place_building(c: SimCharacter, part_id: String, origin: Vector2i, rotation: int) -> SimBuilding:
	if not can_place(c, part_id, origin, rotation).is_empty():
		return null
	var def: Dictionary = data.buildings[part_id]
	for rid: String in def["cost"]:
		c.inventory[rid] = int(c.inventory[rid]) - int(def["cost"][rid])
	var b := SimBuilding.new()
	b.id = _next_building_id
	_next_building_id += 1
	b.part = part_id
	b.owner_id = c.owner_id
	b.origin = origin
	b.rotation = rotation % 2
	b.max_hp = float(def["hp"])
	b.hp = b.max_hp
	b.placed_time = time
	b.cells = SimBuilding.cells_for(def["size"], origin, b.rotation)
	map.add_building(b)
	events.append({"type": "build", "id": c.id, "building": b.id, "part": part_id})
	if part_id == "anchor":
		claims.on_anchor_placed(self, b)
	if is_sensor(b):
		b.label = "Sensor %d" % sensors_of(c.owner_id).size()
		unlock(c.owner_id, "owned_sensor", c)
	if is_turret(b):
		var count := 0
		for other: SimBuilding in map.buildings.values():
			if is_turret(other) and other.owner_id == c.owner_id:
				count += 1
		b.label = "Turret %d" % count
	if is_container(b):
		unlock(c.owner_id, "owned_container", c)
	if is_sensor(b) or is_container(b):
		refresh_places(c.owner_id)
	return b


## Darf der Charakter dieses Teil abreißen (eigenes Teil, live, in Reichweite)?
func can_demolish(c: SimCharacter, b: SimBuilding) -> bool:
	return b != null and b.owner_id == c.owner_id and c.control == SimCharacter.Controller.PLAYER and not c.dead \
		and b.center().distance_to(c.pos) <= data.balf("building.reach")


## Entfernt ein Bauteil; mit refund_to bekommt der Abreißende einen Teil der Kosten zurück.
func remove_building(id: int, refund_to: SimCharacter = null) -> bool:
	var b: SimBuilding = map.buildings.get(id)
	if b == null:
		return false
	if refund_to != null:
		var def: Dictionary = data.buildings[b.part]
		var capacity := data.bali("inventory.capacity")
		for rid: String in def["cost"]:
			var back := int(floorf(float(def["cost"][rid]) * data.balf("building.refund_fraction")))
			back = mini(back, capacity - refund_to.inventory_count())
			if back > 0:
				refund_to.inventory[rid] = int(refund_to.inventory.get(rid, 0)) + back
	map.remove_building(id)
	claims.on_building_removed(self, id)
	if is_sensor(b) or is_container(b):
		refresh_places(b.owner_id)
	events.append({"type": "demolish", "building": id, "id": refund_to.id if refund_to != null else -1})
	return true


## Schaden an einem Bauteil (Nahkampf gegen Holz, später Werkzeuge/Sprengsätze). Bei 0 verschwindet es.
## Kann die aktive Waffe dieses Bauteil einschlagen? (Holz mit allem, Stein nur mit Eisenwerkzeug.)
func can_break(c: SimCharacter, b: SimBuilding) -> bool:
	var tier := String(data.buildings[b.part]["tier"])
	var breaks: Array = data.items.get(c.active_weapon, {}).get("breaks", ["wood"])
	return breaks.has(tier)


func damage_building(b: SimBuilding, amount: float, attacker_id: int) -> void:
	if bool(data.buildings.get(b.part, {}).get("indestructible", false)):
		return
	b.hp = maxf(0.0, b.hp - amount)
	events.append({"type": "building_hit", "building": b.id, "attacker": attacker_id, "damage": amount, "pos": b.center()})
	if b.hp <= 0.0:
		if is_trade_table(b):
			_loot_table(b, attacker_id)
		map.remove_building(b.id)
		claims.on_building_removed(self, b.id)
		if is_sensor(b) or is_container(b):
			refresh_places(b.owner_id)
		events.append({"type": "building_destroyed", "building": b.id, "attacker": attacker_id, "pos": b.center()})


# --- Sensoren und Fallen --------------------------------------------------

func is_sensor(b: SimBuilding) -> bool:
	return b != null and data.buildings.get(b.part, {}).has("sensor_radius")


func is_trap(b: SimBuilding) -> bool:
	return b != null and data.buildings.get(b.part, {}).has("trap_damage")


## Für Fremde unsichtbare Bauteile (Fallen) sieht nur der Besitzer.
func building_visible_to(b: SimBuilding, owner_id: String) -> bool:
	return not bool(data.buildings.get(b.part, {}).get("hidden", false)) or allied(b.owner_id, owner_id)


## Kennung eines Bauteils als Ort ("b<id>").
static func place_id_of(b: SimBuilding) -> String:
	return "b%d" % b.id


## Eigene Sensoren, die gerade ausgelöst sind (Orts-Kennungen), für die Bedingung 'Sensor … ausgelöst'.
func triggered_sensors_of(owner_id: String) -> Array:
	var result := []
	for b: SimBuilding in map.buildings.values():
		if allied(b.owner_id, owner_id) and is_sensor(b) and time < b.triggered_until:
			result.append(place_id_of(b))
	return result


func sensors_of(owner_id: String, include_allies: bool = false) -> Array[SimBuilding]:
	var result: Array[SimBuilding] = []
	for b: SimBuilding in map.buildings.values():
		if (b.owner_id == owner_id or (include_allies and allied(b.owner_id, owner_id))) and is_sensor(b):
			result.append(b)
	return result


## Bauteile, in die geliefert werden kann (Anker nimmt Holz für den Unterhalt, Handelstisch alles).
func is_container(b: SimBuilding) -> bool:
	return b != null and (b.part == "anchor" or is_trade_table(b) or is_depot(b) or is_turret(b))


func is_turret(b: SimBuilding) -> bool:
	return b != null and data.buildings.get(b.part, {}).has("turret")


## Munition ins eigene Turret laden (live per E oder NPC-Lieferung). Rückgabe: geladene Menge.
func turret_load(c: SimCharacter, b: SimBuilding, amount: int) -> int:
	if not is_turret(b) or not allied(b.owner_id, c.owner_id) or c.dead:
		return 0
	var spec: Dictionary = data.buildings[b.part]["turret"]
	var ammo := String(spec["ammo"])
	var room := int(spec["capacity"]) - int(b.contents.get(ammo, 0))
	amount = mini(mini(amount, int(c.inventory.get(ammo, 0))), room)
	if amount <= 0:
		return 0
	c.inventory[ammo] = int(c.inventory[ammo]) - amount
	b.contents[ammo] = int(b.contents.get(ammo, 0)) + amount
	events.append({"type": "turret_loaded", "id": c.id, "building": b.id, "amount": amount, "stock": int(b.contents[ammo])})
	return amount


## Turret in Reichweite des eigenen Besitzers, sonst null.
func turret_near(c: SimCharacter) -> SimBuilding:
	for b: SimBuilding in map.buildings.values():
		if is_turret(b) and allied(b.owner_id, c.owner_id) and b.center().distance_to(c.pos) <= data.balf("character.interact_range") + 0.5:
			return b
	return null


## Sprengsätze: nach der Lunte trifft die Explosion alle Bauteile (jede Stufe) und Charaktere im Radius.
func _update_bombs() -> void:
	for id: int in map.buildings.keys():
		var b: SimBuilding = map.buildings.get(id)
		if b == null:
			continue
		var spec: Dictionary = data.buildings[b.part].get("bomb", {})
		if spec.is_empty() or time < b.placed_time + float(spec["fuse"]):
			continue
		var center := b.center()
		var radius := float(spec["radius"])
		map.remove_building(id)
		claims.on_building_removed(self, id)
		events.append({"type": "explosion", "building": id, "owner": b.owner_id, "pos": center, "radius": radius})
		for other_id: int in map.buildings.keys():
			var other: SimBuilding = map.buildings.get(other_id)
			if other != null and other.center().distance_to(center) <= radius:
				damage_building(other, float(spec["building_damage"]), -1)
		for c: SimCharacter in spatial.query(center, radius):
			if not c.dead and c.pos.distance_to(center) <= radius and not in_peace_zone(c.pos):
				apply_damage(c, float(spec["character_damage"]), (c.pos - center).normalized() if c.pos != center else Vector2.DOWN, -1, "", "einen Sprengsatz")


## Leichen verrotten samt Inventar nach corpse_rot_hours (Senke); Wölfe räumt der Nachschub auf.
func _update_corpses() -> void:
	var rot_after := data.balf("combat.corpse_rot_hours") * 3600.0
	for id: int in characters.keys():
		var c: SimCharacter = characters[id]
		if c.dead and c.kind == SimCharacter.Kind.PLAYER and time - c.death_time >= rot_after:
			characters.erase(id)
			events.append({"type": "corpse_rotted", "id": id, "owner": c.owner_id, "name": c.name})


## Turrets: nächster sichtbarer Fremder oder Tier im Radius mit Sichtlinie, ein Schuss je Abklingzeit, eine Kugel je Schuss.
func _update_turrets(_dt: float) -> void:
	for b: SimBuilding in map.buildings.values():
		if not is_turret(b) or time < b.triggered_until:
			continue
		var spec: Dictionary = data.buildings[b.part]["turret"]
		var ammo := String(spec["ammo"])
		if int(b.contents.get(ammo, 0)) <= 0:
			continue
		var radius := float(spec["radius"])
		var center := b.center()
		var target: SimCharacter = null
		var best := radius * radius
		for other: SimCharacter in spatial.query(center, radius):
			if other.dead or other.hidden or allied(other.owner_id, b.owner_id) or in_peace_zone(other.pos):
				continue
			var d := other.pos.distance_squared_to(center)
			# Sichtlinie ab dem Rand des eigenen Bauteils (sonst blockiert sich das Turret selbst), Bauteile zählen
			var muzzle := center + (other.pos - center).normalized() * 0.85
			if d <= best and SimNav.line_clear(map, muzzle, other.pos, 0.1, b.owner_id, data):
				best = d
				target = other
		if target == null:
			continue
		b.contents[ammo] = int(b.contents[ammo]) - 1
		b.triggered_until = time + float(spec["cooldown"])
		events.append({"type": "turret_shot", "building": b.id, "owner": b.owner_id, "target": target.id, "from": center, "to": target.pos})
		apply_damage(target, float(spec["damage"]), (target.pos - center).normalized(), -1, "", "ein Turret")


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
		if is_depot(b):
			places[place_id_of(b)] = {"name": b.label, "pos": b.center()}
			continue
		if not allied(b.owner_id, owner_id):
			continue
		# Bauteile der Gildenmitglieder sind Orte mit Besitzerzusatz ("Anker (Ben)")
		var suffix := "" if b.owner_id == owner_id else " (%s)" % b.owner_id
		if is_sensor(b):
			places[place_id_of(b)] = {"name": b.label + suffix, "pos": b.center()}
		elif b.part == "anchor":
			places[place_id_of(b)] = {"name": "Anker" + suffix, "pos": b.center()}
		elif is_trade_table(b):
			if b.owner_id == owner_id:
				tables += 1
			places[place_id_of(b)] = {"name": ("Handelstisch %d" % tables if b.owner_id == owner_id else "Handelstisch") + suffix, "pos": b.center()}
		elif is_turret(b):
			places[place_id_of(b)] = {"name": b.label + suffix, "pos": b.center()}
	for c: SimCharacter in characters.values():
		if c.owner_id == owner_id:
			c.extra_places = places.duplicate(true)


func _update_sensors_and_traps(dt: float) -> void:
	if map.buildings.is_empty():
		return
	for id: int in map.buildings.keys():
		var b: SimBuilding = map.buildings.get(id)
		if b == null:
			continue
		var def: Dictionary = data.buildings[b.part]
		if def.has("sensor_radius"):
			var was_triggered := time < b.triggered_until
			var center := b.center()
			for other: SimCharacter in spatial.query(center, float(def["sensor_radius"])):
				if other.dead or allied(other.owner_id, b.owner_id) or other.pos.distance_to(center) > float(def["sensor_radius"]):
					continue
				b.triggered_until = time + float(def.get("sensor_hold", 5.0))
				if not was_triggered:
					events.append({"type": "sensor_triggered", "building": b.id, "owner": b.owner_id, "by": other.id, "label": b.label})
				break
		elif def.has("trap_damage"):
			for other: SimCharacter in spatial.query(b.center(), 1.5):
				if other.dead or allied(other.owner_id, b.owner_id):
					continue
				var half := SimBuilding.half_cell_of(other.pos)
				if not b.cells.has(half):
					continue
				apply_damage(other, float(def["trap_damage"]), Vector2.DOWN, -1)
				events.append({"type": "trap_triggered", "building": b.id, "owner": b.owner_id, "by": other.id, "pos": b.center()})
				map.remove_building(b.id)
				break


## Liefert alles von `rid` in ein eigenes Bauteil (Anker: nur Holz; Handelstisch: alles) in Reichweite. Rückgabe: Menge.
func deliver_to(c: SimCharacter, b: SimBuilding, rid: String) -> int:
	if not is_container(b) or (not allied(b.owner_id, c.owner_id) and not is_depot(b)) or c.dead:
		return 0
	if b.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return 0
	var amount := int(c.inventory.get(rid, 0))
	if amount <= 0:
		return 0
	if is_depot(b):
		if not depot_deposit(c, b, rid, amount, true).is_empty():
			return 0
		return amount - int(c.inventory.get(rid, 0))
	if is_turret(b):
		return turret_load(c, b, amount) if rid == String(data.buildings[b.part]["turret"]["ammo"]) else 0
	if b.part == "anchor":
		if rid != "wood":
			return 0
		var claim := claims.claim_at(SimMap.cell_of(b.center()))  # auch der Anker eines Gildenmitglieds
		if claim == null:
			claim = claims.claim_of_owner(c.owner_id)
		return claims.deposit(self, c, claim, amount)
	var before := int(b.contents.get(rid, 0))
	if not table_deposit(c, b, rid, amount, true).is_empty():
		return 0
	return int(b.contents.get(rid, 0)) - before


## Eigenes Bauteil mit Aufnahme (Anker/Tisch) nahe einer Position, sonst null.
func container_near(owner_id: String, pos: Vector2, radius: float) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := radius
	for b: SimBuilding in map.buildings.values():
		if not is_container(b) or (not allied(b.owner_id, owner_id) and not is_depot(b)):
			continue
		var d := b.center().distance_to(pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


# --- Neutraler Markt und Depot --------------------------------------------

func is_depot(b: SimBuilding) -> bool:
	return b != null and bool(data.buildings.get(b.part, {}).get("depot", false))


func depots() -> Array[SimBuilding]:
	var result: Array[SimBuilding] = []
	for b: SimBuilding in map.buildings.values():
		if is_depot(b):
			result.append(b)
	result.sort_custom(func(a: SimBuilding, b: SimBuilding) -> bool: return a.id < b.id)
	return result


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


## Gebühr eines Depots (nach seiner Zone).
func depot_fee_of(b: SimBuilding) -> float:
	return float(zone_at(b.center()).get("depot_fee", 0.2))


## Depot in Interaktionsreichweite, sonst null.
func depot_near(c: SimCharacter) -> SimBuilding:
	for b: SimBuilding in map.buildings.values():
		if is_depot(b) and b.center().distance_to(c.pos) <= data.balf("character.interact_range") + 0.5:
			return b
	return null


## Eigener Bestand in einem Depot (Verweis). Im Client-Spiegel liegt der eigene Bestand in `contents`.
func depot_stock(b: SimBuilding, owner_id: String) -> Dictionary:
	if b.stores.has(owner_id):
		return b.stores[owner_id]
	return b.contents if b.stores.is_empty() else {}


func depot_stock_count(b: SimBuilding, owner_id: String) -> int:
	var total := 0
	for amount: int in depot_stock(b, owner_id).values():
		total += amount
	return total


func _depot_reason(c: SimCharacter, b: SimBuilding, allow_npc: bool) -> String:
	if not is_depot(b):
		return "kein Depot"
	if c.dead or (c.control != SimCharacter.Controller.PLAYER and not allow_npc):
		return "nur live"
	if b.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	return ""


## Einlagern: die Gebühr (Anteil) geht verloren – die Senke des neutralen Markts. Rückgabe: Grund oder leer.
func depot_deposit(c: SimCharacter, b: SimBuilding, rid: String, amount: int, allow_npc: bool = false) -> String:
	var reason := _depot_reason(c, b, allow_npc)
	if not reason.is_empty():
		return reason
	if not data.resources.has(rid):
		return "unbekannter Rohstoff"
	if bool(data.resources[rid].get("raid_good", false)) and not bool(zone_at(b.center()).get("raid_goods", false)):
		return "Raidware: am neutralen Markt nicht handelbar"
	amount = mini(amount, int(c.inventory.get(rid, 0)))
	if amount <= 0:
		return "nichts einzulagern"
	var capacity := data.bali("market.depot_capacity")
	var room := capacity - depot_stock_count(b, c.owner_id)
	if room <= 0:
		return "Depot voll (%d)" % capacity
	var keep_fraction := 1.0 - depot_fee_of(b)
	var kept := int(floorf(float(amount) * keep_fraction))
	if kept <= 0:
		return "zu wenig, die Gebühr frisst alles"
	if kept > room:
		amount = mini(int(ceilf(float(room) / keep_fraction)), int(c.inventory.get(rid, 0)))
		kept = mini(room, int(floorf(float(amount) * keep_fraction)))
	if not b.stores.has(c.owner_id):
		b.stores[c.owner_id] = {}
	b.stores[c.owner_id][rid] = int(b.stores[c.owner_id].get(rid, 0)) + kept
	c.inventory[rid] = int(c.inventory[rid]) - amount
	if c.control == SimCharacter.Controller.PLAYER:
		unlock(c.owner_id, "owned_container", c)
	events.append({"type": "depot_deposit", "id": c.id, "building": b.id, "resource": rid, "amount": amount, "kept": kept, "fee": amount - kept})
	return ""


## Entnehmen ist gebührenfrei; nur so viel, wie ins Inventar passt.
func depot_withdraw(c: SimCharacter, b: SimBuilding, rid: String, amount: int) -> String:
	var reason := _depot_reason(c, b, false)
	if not reason.is_empty():
		return reason
	var stock := depot_stock(b, c.owner_id)
	amount = mini(amount, int(stock.get(rid, 0)))
	if amount <= 0:
		return "nichts im Depot"
	var room := data.bali("inventory.capacity") - c.inventory_count()
	if room <= 0:
		return "Inventar voll"
	amount = mini(amount, room)
	stock[rid] = int(stock[rid]) - amount
	if int(stock[rid]) <= 0:
		stock.erase(rid)
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + amount
	events.append({"type": "depot_withdraw", "id": c.id, "building": b.id, "resource": rid, "amount": amount})
	return ""


# --- Schilder -------------------------------------------------------------

func is_sign(b: SimBuilding) -> bool:
	return b != null and bool(data.buildings.get(b.part, {}).get("sign", false))


## Schild in Interaktionsreichweite (nächstes), sonst null.
func sign_near(c: SimCharacter) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := data.balf("character.interact_range") + 0.5
	for b: SimBuilding in map.buildings.values():
		if not is_sign(b):
			continue
		var d := b.center().distance_to(c.pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


## Besitzer beschriftet sein Schild (live). Rückgabe: Grund oder leer.
func set_sign_text(c: SimCharacter, b: SimBuilding, text: String) -> String:
	if not is_sign(b):
		return "kein Schild"
	if b.owner_id != c.owner_id:
		return "nicht dein Schild"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if b.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	b.label = text.strip_edges().substr(0, data.bali("building.sign_max_length"))
	events.append({"type": "sign_text", "building": b.id, "id": c.id})
	return ""


# --- Handelstisch ---------------------------------------------------------

func is_trade_table(b: SimBuilding) -> bool:
	return b != null and bool(data.buildings.get(b.part, {}).get("trade", false))


## Handelstisch in Interaktionsreichweite des Charakters (nächster), sonst null.
func trade_table_near(c: SimCharacter) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := data.balf("character.interact_range") + 0.5
	for b: SimBuilding in map.buildings.values():
		if not is_trade_table(b):
			continue
		var d := b.center().distance_to(c.pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


func _table_owner_reason(c: SimCharacter, b: SimBuilding, allow_npc: bool = false) -> String:
	if not is_trade_table(b):
		return "kein Handelstisch"
	if b.owner_id != c.owner_id:
		return "nicht dein Tisch"
	if c.dead or (c.control != SimCharacter.Controller.PLAYER and not allow_npc):
		return "nur live"
	if b.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	return ""


## Besitzer legt Waren hinein. Rückgabe: Grund oder leer.
func table_deposit(c: SimCharacter, b: SimBuilding, rid: String, amount: int, allow_npc: bool = false) -> String:
	var reason := _table_owner_reason(c, b, allow_npc)
	if not reason.is_empty():
		return reason
	if not data.resources.has(rid) or amount <= 0:
		return "ungültig"
	amount = mini(amount, int(c.inventory.get(rid, 0)))
	amount = mini(amount, data.bali("building.table_capacity") - b.contents_count())
	if amount <= 0:
		return "nichts zu lagern oder Tisch voll"
	c.inventory[rid] = int(c.inventory[rid]) - amount
	b.contents[rid] = int(b.contents.get(rid, 0)) + amount
	events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


func table_withdraw(c: SimCharacter, b: SimBuilding, rid: String, amount: int) -> String:
	var reason := _table_owner_reason(c, b)
	if not reason.is_empty():
		return reason
	amount = mini(amount, int(b.contents.get(rid, 0)))
	amount = mini(amount, data.bali("inventory.capacity") - c.inventory_count())
	if amount <= 0:
		return "nichts zu entnehmen oder Inventar voll"
	b.contents[rid] = int(b.contents[rid]) - amount
	if b.contents[rid] <= 0:
		b.contents.erase(rid)
	c.inventory[rid] = int(c.inventory.get(rid, 0)) + amount
	events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


## Angebote setzen: Liste von {sell, sell_amount, price, price_amount}.
func table_set_offers(c: SimCharacter, b: SimBuilding, offers: Array) -> String:
	var reason := _table_owner_reason(c, b)
	if not reason.is_empty():
		return reason
	if offers.size() > data.bali("building.table_max_offers"):
		return "höchstens %d Angebote" % data.bali("building.table_max_offers")
	var clean := []
	for offer: Variant in offers:
		if not (offer is Dictionary):
			return "ungültiges Angebot"
		var sell := String(offer.get("sell", ""))
		var price := String(offer.get("price", ""))
		var sell_amount := int(offer.get("sell_amount", 0))
		var price_amount := int(offer.get("price_amount", 0))
		if not data.resources.has(sell) or not data.resources.has(price) or sell == price:
			return "ungültiges Angebot"
		if sell_amount < 1 or sell_amount > 99 or price_amount < 1 or price_amount > 99:
			return "Mengen 1 bis 99"
		clean.append({"sell": sell, "sell_amount": sell_amount, "price": price, "price_amount": price_amount})
	b.offers = clean
	events.append({"type": "table_change", "building": b.id, "id": c.id})
	return ""


## Kauf durch einen Live-Charakter: zahlt den Preis in den Tisch, nimmt die Ware. Rückgabe: Grund oder leer.
func table_buy(c: SimCharacter, b: SimBuilding, index: int) -> String:
	if not is_trade_table(b):
		return "kein Handelstisch"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if b.center().distance_to(c.pos) > data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	if index < 0 or index >= b.offers.size():
		return "kein solches Angebot"
	var offer: Dictionary = b.offers[index]
	var sell := String(offer["sell"])
	var price := String(offer["price"])
	var sell_amount := int(offer["sell_amount"])
	var price_amount := int(offer["price_amount"])
	if int(b.contents.get(sell, 0)) < sell_amount:
		return "ausverkauft"
	if int(c.inventory.get(price, 0)) < price_amount:
		return "zu wenig %s (%d nötig)" % [data.resources[price]["name"], price_amount]
	if c.inventory_count() - price_amount + sell_amount > data.bali("inventory.capacity"):
		return "Inventar zu voll"
	if b.contents_count() - sell_amount + price_amount > data.bali("building.table_capacity"):
		return "Tisch kann die Bezahlung nicht fassen"
	c.inventory[price] = int(c.inventory[price]) - price_amount
	c.inventory[sell] = int(c.inventory.get(sell, 0)) + sell_amount
	b.contents[sell] = int(b.contents[sell]) - sell_amount
	if b.contents[sell] <= 0:
		b.contents.erase(sell)
	b.contents[price] = int(b.contents.get(price, 0)) + price_amount
	events.append({"type": "trade", "building": b.id, "id": c.id, "owner": b.owner_id, "sell": sell, "sell_amount": sell_amount, "price": price, "price_amount": price_amount})
	return ""


## Tisch zerstört: der Inhalt fällt dem Zerstörer zu (so weit Platz ist), sonst verfällt er.
func _loot_table(b: SimBuilding, attacker_id: int) -> void:
	var taker := get_character(attacker_id)
	if taker == null or b.contents.is_empty():
		return
	var capacity := data.bali("inventory.capacity")
	var taken := {}
	for rid: String in b.contents.keys():
		var moved := mini(int(b.contents[rid]), capacity - taker.inventory_count())
		if moved <= 0:
			continue
		taker.inventory[rid] = int(taker.inventory.get(rid, 0)) + moved
		taken[rid] = moved
	if not taken.is_empty():
		events.append({"type": "loot", "id": taker.id, "from": -1, "items": taken, "equipment": [], "table": b.id})
	b.contents.clear()


## Bauteil vor dem Charakter in Nahkampfreichweite (entlang der Blickrichtung getastet).
func building_in_reach(c: SimCharacter, reach: float) -> SimBuilding:
	var steps := maxi(1, ceili(reach / 0.25))
	for i in range(1, steps + 1):
		var b := map.building_at(c.pos + c.facing * (reach * float(i) / float(steps)))
		if b != null:
			return b
	return null


func _update_buildings(dt: float) -> void:
	if map.buildings.is_empty():
		return
	var foreign_multiplier := data.balf("claim.foreign_decay_multiplier")
	for id: int in map.buildings.keys():
		var b: SimBuilding = map.buildings[id]
		var decay := float(data.buildings[b.part]["decay_per_hour"]) / 3600.0 * dt
		if decay <= 0.0:
			continue
		# Auf fremdem oder verlorenem Land verfällt es schneller (Claim geschrumpft, Anker weg)
		var claim := claims.claim_at(SimMap.cell_of(b.center()))
		if claim != null and not allied(claim.owner_id, b.owner_id):
			decay *= foreign_multiplier
		b.hp -= decay
		if b.hp <= 0.0:
			map.remove_building(id)
			claims.on_building_removed(self, id)
			if is_sensor(b) or is_container(b):
				refresh_places(b.owner_id)
			events.append({"type": "building_destroyed", "building": id, "attacker": -1, "pos": b.center(), "decayed": true})


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
		_apply_intent(c, intent if intent != null else SimIntent.new(), step_dt)
	_intents.clear()
	spatial.rebuild(characters)
	_update_projectiles(dt)
	_update_hunger(dt)
	_update_nodes(dt)
	_update_buildings(dt)
	_update_sensors_and_traps(dt)
	_update_turrets(dt)
	_update_bombs()
	_update_corpses()
	claims.update(self, dt)
	_update_wolves(dt)


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
		return action == "fight_back" or action == "attack"
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
		var speed := c.move_speed * (1.0 - c.armor_slow) * (1.0 - (effect_slow(c) if not c.effects.is_empty() else 0.0))
		if c.is_weakened():
			speed *= data.balf("character.weakened_speed_multiplier")
		c.pos = map.resolve_move(c.pos, move * speed * dt, c.collision_radius, c.owner_id, data)
		if c.hidden:
			reveal(c)

	if intent.interact:
		if not _loot(c) and not _deposit_at_anchor(c) and not _load_turret_near(c):
			_gather(c, dt, intent.gather_cell)
	else:
		c.gather_progress = 0.0
		c.gather_target = Vector2i(-1, -1)

	if intent.eat:
		eat(c)
	if intent.shoot:
		_attack(c)
	if intent.melee:
		_melee(c)
	_update_healing(c, intent, dt)
	_update_hiding(c, intent, dt)
	_update_effects(c, dt)

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
	var b := turret_near(c)
	if b == null:
		return false
	var ammo := String(data.buildings[b.part]["turret"]["ammo"])
	return turret_load(c, b, int(c.inventory.get(ammo, 0))) > 0


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
		for rid: String in taken:
			if data.resources[rid].has("heal"):
				unlock(c.owner_id, "owned_bandage", c)
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
	var ammo := String(weapon.get("ammo", ""))
	if not ammo.is_empty():
		if int(c.inventory.get(ammo, 0)) <= 0:
			c.fire_cooldown = float(weapon["cooldown"])  # Klicken ohne Munition: kurze Pause statt Dauerfeuer-Ereignisse
			events.append({"type": "no_ammo", "id": c.id, "weapon": c.active_weapon})
			return
		c.inventory[ammo] = int(c.inventory[ammo]) - 1
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
	wear(c, c.active_weapon)


func _melee(c: SimCharacter) -> void:
	if c.bite_cooldown > 0.0 or c.melee_damage <= 0.0:
		return
	var target := nearest_enemy(c, c.melee_range)
	if target == null:
		# Nur Live-Spieler schlagen Bauteile (Holz) ein; NPCs und Tiere nie (nur Live kann Nehmen und Verändern)
		if c.control != SimCharacter.Controller.PLAYER or c.kind != SimCharacter.Kind.PLAYER:
			return
		var b := building_in_reach(c, c.melee_range)
		if b == null or not can_break(c, b):
			events.append({"type": "too_hard", "id": c.id, "building": b.id} if b != null else {"type": "swing", "id": c.id})
			return
		c.bite_cooldown = c.melee_cooldown
		reveal(c)
		damage_building(b, c.melee_damage * data.balf("building.melee_damage_multiplier"), c.id)
		wear(c, c.active_weapon)
		return
	c.bite_cooldown = c.melee_cooldown
	reveal(c)
	apply_damage(target, c.melee_damage, (target.pos - c.pos).normalized(), c.id, c.melee_effect)
	wear(c, c.active_weapon)


## Nächster lebender, sichtbarer Charakter eines anderen Besitzers im Radius.
func nearest_enemy(c: SimCharacter, radius: float) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for other: SimCharacter in spatial.query(c.pos, radius):
		if other == c or other.dead or other.hidden or allied(other.owner_id, c.owner_id):
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
			if not map.is_walkable(SimMap.cell_of(p.pos)) or map.building_at(p.pos) != null or in_peace_zone(p.pos):
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
func apply_damage(victim: SimCharacter, base_damage: float, hit_dir: Vector2, attacker_id: int, effect: String = "", attacker_label: String = "") -> Dictionary:
	var peace_attacker := get_character(attacker_id)
	if in_peace_zone(victim.pos) or (peace_attacker != null and in_peace_zone(peace_attacker.pos)):
		events.append({"type": "market_peace", "id": victim.id, "attacker": attacker_id, "pos": victim.pos})
		return {}
	var side := SimCombat.hit_side(victim.facing, hit_dir, data.balf("combat.front_arc_degrees"), data.balf("combat.back_arc_degrees"))
	var amount := SimCombat.damage(base_damage, victim.armor, side, data)
	victim.hp = maxf(0.0, victim.hp - amount)
	var armor_item := armor_item_of(victim)
	if not armor_item.is_empty():
		wear(victim, armor_item)
	victim.last_damage_time = time
	victim.last_attacker_id = attacker_id
	reveal(victim)
	var attacker := get_character(attacker_id)
	var event := {"type": "hit", "id": victim.id, "attacker": attacker_id, "damage": amount, "side": side, "pos": victim.pos, "known": attacker != null and knows_name(victim, attacker)}
	events.append(event)
	if attacker != null and attacker.kind == SimCharacter.Kind.PLAYER and attacker.control == SimCharacter.Controller.RULES \
			and victim.kind == SimCharacter.Kind.PLAYER and not allied(victim.owner_id, attacker.owner_id):
		unlock(victim.owner_id, "attacked_by_npc", victim)
	if victim.hp <= 0.0:
		_kill(victim, attacker_id, "", attacker_label)
	elif not effect.is_empty():
		apply_effect(victim, effect, attacker_id)
	return event


func _kill(victim: SimCharacter, attacker_id: int, cause: String = "", attacker_label: String = "") -> void:
	victim.dead = true
	victim.hp = 0.0
	victim.hidden = false
	victim.effects.clear()
	victim.death_time = time
	var attacker := get_character(attacker_id)
	var attacker_name := describe(victim, attacker) if attacker != null else (attacker_label if not attacker_label.is_empty() else "Unbekannt")
	events.append({"type": "death", "id": victim.id, "attacker": attacker_id, "cause": cause})
	if victim.kind == SimCharacter.Kind.PLAYER:
		SimChronicle.add(self, victim, ("%s, zuletzt getroffen von %s" % [cause, attacker_name]) if not cause.is_empty() else "gestorben durch %s" % attacker_name)
	if attacker != null and attacker.kind == SimCharacter.Kind.PLAYER and attacker.control == SimCharacter.Controller.RULES:
		SimChronicle.add(self, attacker, "%s getötet" % describe(attacker, victim))


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
			rate *= effect_hunger_multiplier(c)
		c.hunger = maxf(0.0, c.hunger - rate * dt)
		# Krankheit als Ereignis: trifft zufällig, live wie offline
		if rng.randf() < data.balf("effects.sick.chance_per_hour") * dt / 3600.0:
			apply_effect(c, "sick", -1)


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
