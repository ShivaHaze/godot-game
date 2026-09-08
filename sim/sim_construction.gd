class_name SimConstruction
extends RefCounted
## Bauen (nur live): Setzen und Abreißen von Bauteilen auf dem Halbkachelraster, Schaden und Verfall, Schilder.
## Design: nur Live kann Nehmen und Verändern – NPCs bauen und brechen nie. Reine Logik über dem Weltzustand.


## Warum ein Bauteil hier nicht gesetzt werden kann; leer = möglich.
static func can_place(world: SimWorld, c: SimCharacter, part_id: String, origin: Vector2i, rotation: int) -> String:
	var def: Dictionary = world.data.buildings.get(part_id, {})
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
		if not world.map.is_walkable(tile):
			return "kein freier Boden"
		if not world.map.zone(tile).is_empty():
			return String(world.zone_def(world.map.zone(tile)).get("build_reason", "hier wird nicht gebaut"))
		if world.map.built_half.has(half):
			return "schon bebaut"
		center += SimBuilding.half_cell_center(half)
	center /= cells.size()
	if center.distance_to(c.pos) > world.data.balf("building.reach"):
		return "zu weit weg"
	for other: SimCharacter in world.characters.values():
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
			return "zu wenig %s (%d nötig)" % [world.data.resources[rid]["name"], int(def["cost"][rid])]
	# Land: nur Eigentümer bauen auf einem Claim; Anker haben eigene Regeln
	var anchor_tile := SimMap.cell_of(center)
	if part_id == "anchor":
		var reason := world.claims.anchor_reason(world.data, c, anchor_tile)
		if not reason.is_empty():
			return reason
	if bool(def.get("one_per_owner", false)):
		for b: SimBuilding in world.map.buildings.values():
			if b.owner_id == c.owner_id and b.part == part_id:
				return "du hast schon %s" % [def["name"]]
	if def.has("next_to_resource"):
		var wanted: Array = def["next_to_resource"]
		var adjacent := false
		for half: Vector2i in cells:
			var tile := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
			for step: Vector2i in SimMap.NEIGHBORS_4:
				var node := world.map.node_at(tile + step)
				if node != null and wanted.has(node.resource):
					adjacent = true
		if not adjacent:
			var names: PackedStringArray = []
			for rid: String in wanted:
				names.append(String(world.data.resources[rid]["name"]))
			return "muss neben %s stehen" % " oder ".join(names)
	for half: Vector2i in cells:
		var tile := Vector2i(floori(half.x / 2.0), floori(half.y / 2.0))
		if world.claims.is_foreign(tile, c.owner_id) and not bool(def.get("anywhere", false)):
			return "fremder Claim"
		if bool(def.get("claim_only", false)):
			var own := world.claims.claim_at(tile)
			if own == null or own.owner_id != c.owner_id:
				return "nur im eigenen Claim"
	return ""


## Setzt ein Bauteil (nur live). null, wenn nicht möglich.
static func place_building(world: SimWorld, c: SimCharacter, part_id: String, origin: Vector2i, rotation: int) -> SimBuilding:
	if not can_place(world, c, part_id, origin, rotation).is_empty():
		return null
	var def: Dictionary = world.data.buildings[part_id]
	for rid: String in def["cost"]:
		c.inventory[rid] = int(c.inventory[rid]) - int(def["cost"][rid])
	var b := SimBuilding.new()
	b.id = world._next_building_id
	world._next_building_id += 1
	b.part = part_id
	b.owner_id = c.owner_id
	b.origin = origin
	b.rotation = rotation % 2
	b.max_hp = float(def["hp"])
	b.hp = b.max_hp
	b.placed_time = world.time
	b.cells = SimBuilding.cells_for(def["size"], origin, b.rotation)
	world.map.add_building(b)
	world.events.append({"type": "build", "id": c.id, "building": b.id, "part": part_id})
	if part_id == "anchor":
		world.claims.on_anchor_placed(world, b)
	if SimDefense.is_sensor(world, b):
		b.label = "Sensor %d" % SimDefense.sensors_of(world, c.owner_id).size()
	if SimDefense.is_turret(world, b):
		var count := 0
		for other: SimBuilding in world.map.buildings.values():
			if SimDefense.is_turret(world, other) and other.owner_id == c.owner_id:
				count += 1
		b.label = "Turret %d" % count
	if SimDefense.is_sensor(world, b) or SimTrade.is_container(world, b):
		world.refresh_places(c.owner_id)
	return b


## Darf der Charakter dieses Teil abreißen (eigenes Teil, live, in Reichweite)?
static func can_demolish(world: SimWorld, c: SimCharacter, b: SimBuilding) -> bool:
	return b != null and b.owner_id == c.owner_id and c.control == SimCharacter.Controller.PLAYER and not c.dead \
		and b.center().distance_to(c.pos) <= world.data.balf("building.reach")


## Entfernt ein Bauteil; mit refund_to bekommt der Abreißende einen Teil der Kosten zurück.
static func remove_building(world: SimWorld, id: int, refund_to: SimCharacter = null) -> bool:
	var b: SimBuilding = world.map.buildings.get(id)
	if b == null:
		return false
	if refund_to != null:
		var def: Dictionary = world.data.buildings[b.part]
		var capacity := world.data.bali("inventory.capacity")
		for rid: String in def["cost"]:
			var back := int(floorf(float(def["cost"][rid]) * world.data.balf("building.refund_fraction")))
			back = mini(back, capacity - refund_to.inventory_count())
			if back > 0:
				refund_to.inventory[rid] = int(refund_to.inventory.get(rid, 0)) + back
	world.map.remove_building(id)
	world.claims.on_building_removed(world, id)
	if SimDefense.is_sensor(world, b) or SimTrade.is_container(world, b):
		world.refresh_places(b.owner_id)
	world.events.append({"type": "demolish", "building": id, "id": refund_to.id if refund_to != null else -1})
	return true


## Schaden an einem Bauteil (Nahkampf gegen Holz, später Werkzeuge/Sprengsätze). Bei 0 verschwindet es.
## Kann die aktive Waffe dieses Bauteil einschlagen? (Holz mit allem, Stein nur mit Eisenwerkzeug.)
static func can_break(world: SimWorld, c: SimCharacter, b: SimBuilding) -> bool:
	var tier := String(world.data.buildings[b.part]["tier"])
	var breaks: Array = world.data.items.get(c.active_weapon, {}).get("breaks", ["wood"])
	return breaks.has(tier)


static func damage_building(world: SimWorld, b: SimBuilding, amount: float, attacker_id: int) -> void:
	if bool(world.data.buildings.get(b.part, {}).get("indestructible", false)):
		return
	b.hp = maxf(0.0, b.hp - amount)
	world.events.append({"type": "building_hit", "building": b.id, "attacker": attacker_id, "damage": amount, "pos": b.center()})
	if b.hp <= 0.0:
		if SimTrade.is_trade_table(world, b):
			SimTrade.loot_table(world, b, attacker_id)
		world.map.remove_building(b.id)
		world.claims.on_building_removed(world, b.id)
		if SimDefense.is_sensor(world, b) or SimTrade.is_container(world, b):
			world.refresh_places(b.owner_id)
		world.events.append({"type": "building_destroyed", "building": b.id, "attacker": attacker_id, "pos": b.center()})


static func is_sign(world: SimWorld, b: SimBuilding) -> bool:
	return b != null and bool(world.data.buildings.get(b.part, {}).get("sign", false))


## Schild in Interaktionsreichweite (nächstes), sonst null.
static func sign_near(world: SimWorld, c: SimCharacter) -> SimBuilding:
	var best: SimBuilding = null
	var best_d := world.data.balf("character.interact_range") + 0.5
	for b: SimBuilding in world.map.buildings.values():
		if not is_sign(world, b):
			continue
		var d := b.center().distance_to(c.pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


## Besitzer beschriftet sein Schild (live). Rückgabe: Grund oder leer.
static func set_sign_text(world: SimWorld, c: SimCharacter, b: SimBuilding, text: String) -> String:
	if not is_sign(world, b):
		return "kein Schild"
	if b.owner_id != c.owner_id:
		return "nicht dein Schild"
	if c.control != SimCharacter.Controller.PLAYER or c.dead:
		return "nur live"
	if b.center().distance_to(c.pos) > world.data.balf("character.interact_range") + 0.5:
		return "zu weit weg"
	b.label = text.strip_edges().substr(0, world.data.bali("building.sign_max_length"))
	world.events.append({"type": "sign_text", "building": b.id, "id": c.id})
	return ""


## Bauteil vor dem Charakter in Nahkampfreichweite (entlang der Blickrichtung getastet).
static func building_in_reach(world: SimWorld, c: SimCharacter, reach: float) -> SimBuilding:
	var steps := maxi(1, ceili(reach / 0.25))
	for i in range(1, steps + 1):
		var b := world.map.building_at(c.pos + c.facing * (reach * float(i) / float(steps)))
		if b != null:
			return b
	return null


static func update_decay(world: SimWorld, dt: float) -> void:
	if world.map.buildings.is_empty():
		return
	var foreign_multiplier := world.data.balf("claim.foreign_decay_multiplier")
	for id: int in world.map.buildings.keys():
		var b: SimBuilding = world.map.buildings[id]
		var decay := float(world.data.buildings[b.part]["decay_per_hour"]) / 3600.0 * dt
		if decay <= 0.0:
			continue
		# Auf fremdem oder verlorenem Land verfällt es schneller (Claim geschrumpft, Anker weg)
		var claim := world.claims.claim_at(SimMap.cell_of(b.center()))
		if claim != null and not world.allied(claim.owner_id, b.owner_id):
			decay *= foreign_multiplier
		b.hp -= decay
		if b.hp <= 0.0:
			world.map.remove_building(id)
			world.claims.on_building_removed(world, id)
			if SimDefense.is_sensor(world, b) or SimTrade.is_container(world, b):
				world.refresh_places(b.owner_id)
			world.events.append({"type": "building_destroyed", "building": id, "attacker": -1, "pos": b.center(), "decayed": true})
