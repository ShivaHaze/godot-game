class_name SimEvents
extends RefCounted
## Ereignisse (Design PvE: Bossspawns, Karawanen). Leitwolf: erscheint im Zentrum, zieht weiter, wenn niemand ihn
## erlegt, und lässt Beute in der Leiche. Karawane: Händler mit Kasse, Wachen und Lasttiere ziehen zwischen den Depots
## der Zonen, rasten und handeln in Kupfer (kaufen Waren, verkaufen die Fracht mit Aufschlag); ein Überfall lohnt,
## ist aber gegen die Wachen teuer. Zahlen in balance.json `events`. Reine Logik über dem Weltzustand.


## Der lebende Leitwolf (Ereignis), sonst null.
static func boss_alive(world: SimWorld) -> SimCharacter:
	for c: SimCharacter in world.characters.values():
		if c.boss and not c.dead:
			return c
	return null


## Ereignis Leitwolf: erscheint am Wolf-Spawn, der der Kartenmitte am nächsten liegt (Zentrum wertvoll/tödlich).
static func spawn_boss(world: SimWorld) -> SimCharacter:
	if world.data.wolf_spawns.is_empty():
		return null
	var center := Vector2(world.map.width * 0.5, world.map.height * 0.5)
	var best: Vector2i = world.data.wolf_spawns[0]
	for cell: Vector2i in world.data.wolf_spawns:
		if SimMap.cell_center(cell).distance_to(center) < SimMap.cell_center(best).distance_to(center):
			best = cell
	var spec: Dictionary = world.data.balance["events"]["boss"]
	var c := world.spawn_wolf(SimMap.cell_center(best))
	c.boss = true
	c.name = String(spec.get("name", "Leitwolf"))
	c.max_hp = float(spec["max_hp"])
	c.hp = c.max_hp
	c.armor = float(spec.get("armor", 0.0))
	c.move_speed = float(spec.get("move_speed", c.move_speed))
	c.melee_damage = float(spec["bite_damage"])
	c.logout_time = world.time  # Erscheinungszeit (das Feld ist bei Tieren sonst ungenutzt)
	c.inventory = {}
	for rid: Variant in spec.get("loot", {}):
		if world.data.resources.has(rid):
			c.inventory[String(rid)] = int(spec["loot"][rid])
	world.events.append({"type": "boss_spawned", "id": c.id, "name": c.name})
	return c


## Ereignisse: der Leitwolf kommt alle interval_hours und zieht nach lifetime_hours weiter, wenn niemand ihn erlegt.
static func update(world: SimWorld) -> void:
	if world.next_boss_time < 0.0:
		return
	var boss := boss_alive(world)
	if boss != null:
		if world.time >= boss.logout_time + world.data.balf("events.boss.lifetime_hours") * 3600.0:
			world.characters.erase(boss.id)
			world.events.append({"type": "boss_left", "id": boss.id, "name": boss.name})
		return
	if world.time >= world.next_boss_time:
		world.next_boss_time = world.time + world.data.balf("events.boss.interval_hours") * 3600.0
		spawn_boss(world)


const GLOBAL_EVENTS: Array[String] = ["boss_spawned", "boss_killed", "boss_left", "caravan_spawned", "caravan_rest", "caravan_raided", "caravan_left"]


## Meldung eines Ereignisses für alle (ohne Ortsangabe – Design: global keine Positionsdaten; Markt und Outpost
## sind bekannte Kartenfeatures).
static func event_text(event: Dictionary) -> String:
	var name := String(event.get("name", "Leitwolf"))
	match String(event.get("type", "")):
		"boss_spawned":
			return "Ein %s streift durchs Zentrum." % name
		"boss_killed":
			return "Der %s ist gefallen. Seine Beute liegt bei der Leiche." % name
		"boss_left":
			return "Der %s ist weitergezogen." % name
		"caravan_spawned":
			return "Eine Karawane rastet am %s und handelt in Kupfer." % event.get("zone", "Markt")
		"caravan_rest":
			return "Die Karawane rastet am %s und handelt in Kupfer." % event.get("zone", "Depot")
		"caravan_raided":
			return "Die Karawane wurde überfallen."
		"caravan_left":
			return "Die Karawane ist weitergezogen."
	return ""


# --- Karawane -------------------------------------------------------------

static func caravan_spec(world: SimWorld) -> Dictionary:
	return world.data.balance.get("events", {}).get("caravan", {})


## Depot einer Zone (das erste), sonst null.
static func depot_in_zone(world: SimWorld, zone: String) -> SimBuilding:
	for b: SimBuilding in SimTrade.depots(world):
		if world.map.zone(SimMap.cell_of(b.center())) == zone:
			return b
	return null


static func caravan_active(world: SimWorld) -> bool:
	return not world.caravans.is_empty()


## Neue Karawane am Depot der ersten Routenzone: Händler, Wachen, Lasttiere; sie rastet zuerst. Rückgabe: Kennung oder -1.
static func spawn_caravan(world: SimWorld) -> int:
	var spec := caravan_spec(world)
	var route: Array = spec.get("route", [])
	if route.size() < 2:
		return -1
	for zone: Variant in route:
		if depot_in_zone(world, String(zone)) == null:
			return -1  # Karte ohne diese Zone: keine Karawane
	var start := depot_in_zone(world, String(route[0]))
	var origin := SimMap.cell_of(start.center())
	var id := world.next_caravan_id
	world.next_caravan_id += 1
	var caravan := {"id": id, "leader": -1, "members": [], "stop": 0, "leg": "rest", "goal": start.center(), "target": start.id,
		"rest_until": world.time + float(spec.get("rest_minutes", 10)) * 60.0, "raided_at": -1.0, "attacked": false}
	var slots: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(1, 1)]
	var roles: Array[String] = ["trader"]
	for i in int(spec.get("guards", 2)):
		roles.append("guard")
	for i in int(spec.get("animals", 2)):
		roles.append("animal")
	for i in roles.size():
		var cell := world.map.nearest_walkable_cell(origin + slots[i % slots.size()])
		var member := _spawn_member(world, SimMap.cell_center(cell), roles[i], id)
		if roles[i] == "trader":
			caravan["leader"] = member.id
		caravan["members"].append(member.id)
	for member_id: int in caravan["members"]:
		world.get_character(member_id).caravan_leader_id = int(caravan["leader"])
	world.caravans[id] = caravan
	world.events.append({"type": "caravan_spawned", "caravan": id, "zone": String(world.zone_def(String(route[0])).get("name", route[0]))})
	return id


static func _spawn_member(world: SimWorld, pos: Vector2, role: String, caravan_id: int) -> SimCharacter:
	var whole := caravan_spec(world)
	var spec: Dictionary = whole.get(role, {})
	var c := SimCharacter.new()
	c.id = world.allocate_id()
	c.kind = SimCharacter.Kind.CARAVAN
	c.control = SimCharacter.Controller.CARAVAN_AI
	c.owner_id = "caravan"
	c.caravan_id = caravan_id
	c.caravan_role = role
	c.name = String(spec.get("name", role))
	c.pos = pos
	c.prev_pos = pos
	c.home_pos = pos
	c.logout_pos = pos
	c.max_hp = float(spec.get("max_hp", 50.0))
	c.hp = c.max_hp
	c.armor = float(spec.get("armor", 0.0))
	c.move_speed = float(spec.get("move_speed", 3.6))
	c.collision_radius = world.data.balf("character.collision_radius")
	c.hunger = world.data.balf("hunger.max")
	for item_id: Variant in spec.get("weapons", []):
		if world.data.items.has(item_id):
			c.items.append(String(item_id))
			c.durability[String(item_id)] = {"left": float(world.data.items[item_id]["durability"]), "max": float(world.data.items[item_id]["durability"])}
	if not c.items.is_empty():
		c.active_weapon = c.items[0]
	for rid: Variant in spec.get("inventory", {}):
		if world.data.resources.has(rid):
			c.inventory[String(rid)] = int(spec["inventory"][rid])
	if role == "trader":
		c.inventory[String(whole.get("currency", "copper"))] = int(whole.get("currency_stock", 0))
	SimCrafting.refresh_equipment(world, c)
	world.characters[c.id] = c
	return c


## Karawanen fortschreiben: Rast, Reise, Überfall; neue Karawane, wenn keine unterwegs ist.
static func update_caravans(world: SimWorld) -> void:
	var spec := caravan_spec(world)
	if spec.is_empty() or world.next_caravan_time < 0.0:
		return
	for id: int in world.caravans.keys():
		_update_caravan(world, world.caravans[id], spec)
	if not caravan_active(world) and world.time >= world.next_caravan_time:
		world.next_caravan_time = world.time + float(spec.get("interval_hours", 3)) * 3600.0
		spawn_caravan(world)


static func _update_caravan(world: SimWorld, caravan: Dictionary, spec: Dictionary) -> void:
	var leader := world.get_character(int(caravan["leader"]))
	if not bool(caravan.get("attacked", false)):
		for member_id: int in caravan["members"]:
			var member := world.get_character(member_id)
			if member != null and member.dead:
				caravan["attacked"] = true
				world.events.append({"type": "caravan_raided", "caravan": caravan["id"]})
				break
	var leg := String(caravan["leg"])
	if leg != "raided" and (leader == null or leader.dead):
		caravan["leg"] = "raided"  # ohne Händler bleibt der Rest stehen und zieht später ab
		caravan["raided_at"] = world.time
		return
	match leg:
		"rest":
			if world.time >= float(caravan["rest_until"]):
				var route: Array = spec["route"]
				var next_stop := int(caravan["stop"]) + 1
				if next_stop > route.size():
					_dissolve(world, caravan, "caravan_left")  # Route und Rückweg geschafft
					return
				var depot := depot_in_zone(world, String(route[next_stop % route.size()]))
				if depot == null:
					_dissolve(world, caravan, "caravan_left")
					return
				caravan["stop"] = next_stop
				caravan["leg"] = "travel"
				caravan["target"] = depot.id
				caravan["goal"] = depot.center()
		"travel":
			if leader.pos.distance_to(caravan["goal"]) <= 1.8:
				caravan["leg"] = "rest"
				caravan["rest_until"] = world.time + float(spec.get("rest_minutes", 10)) * 60.0
				world.events.append({"type": "caravan_rest", "caravan": caravan["id"], "zone": String(world.zone_at(caravan["goal"]).get("name", "Depot"))})
		"raided":
			if world.time >= float(caravan["raided_at"]) + float(spec.get("linger_minutes", 30)) * 60.0:
				_dissolve(world, caravan, "")


## Lebende Mitglieder verschwinden (Leichen bleiben als Beute); Meldung optional.
static func _dissolve(world: SimWorld, caravan: Dictionary, event_type: String) -> void:
	for member_id: int in caravan["members"]:
		var member := world.get_character(member_id)
		if member != null and not member.dead:
			world.characters.erase(member_id)
	world.caravans.erase(int(caravan["id"]))
	if not event_type.is_empty():
		world.events.append({"type": event_type, "caravan": caravan["id"]})


# --- Spielstand -----------------------------------------------------------

static func caravans_to_list(world: SimWorld) -> Array:
	var result := []
	for caravan: Dictionary in world.caravans.values():
		var goal: Vector2 = caravan["goal"]
		result.append({"id": caravan["id"], "leader": caravan["leader"], "members": Array(caravan["members"]).duplicate(), "stop": caravan["stop"],
			"leg": caravan["leg"], "goal": [goal.x, goal.y], "target": caravan["target"], "rest_until": caravan["rest_until"],
			"raided_at": caravan["raided_at"], "attacked": caravan.get("attacked", false)})
	return result


static func caravans_from_list(world: SimWorld, list: Array) -> void:
	world.caravans = {}
	for entry: Dictionary in list:
		var members := []
		for m: Variant in entry.get("members", []):
			members.append(int(m))
		var goal: Array = entry.get("goal", [0, 0])
		var id := int(entry["id"])
		world.caravans[id] = {"id": id, "leader": int(entry["leader"]), "members": members, "stop": int(entry.get("stop", 0)), "leg": String(entry.get("leg", "rest")),
			"goal": Vector2(float(goal[0]), float(goal[1])), "target": int(entry.get("target", -1)), "rest_until": float(entry.get("rest_until", 0.0)),
			"raided_at": float(entry.get("raided_at", -1.0)), "attacked": bool(entry.get("attacked", false))}
		world.next_caravan_id = maxi(world.next_caravan_id, id + 1)
