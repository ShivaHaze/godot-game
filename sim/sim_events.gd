class_name SimEvents
extends RefCounted
## Ereignisse (Design PvE: Bossspawns, Karawanen): der Leitwolf erscheint im Zentrum, zieht weiter, wenn niemand ihn
## erlegt, und lässt Beute in der Leiche. Zahlen in balance.json `events`. Reine Logik über dem Weltzustand.


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


## Meldung eines Leitwolf-Ereignisses für alle (ohne Ortsangabe – Design: global keine Positionsdaten).
static func boss_event_text(event: Dictionary) -> String:
	var name := String(event.get("name", "Leitwolf"))
	match String(event.get("type", "")):
		"boss_spawned":
			return "Ein %s streift durchs Zentrum." % name
		"boss_killed":
			return "Der %s ist gefallen. Seine Beute liegt bei der Leiche." % name
		"boss_left":
			return "Der %s ist weitergezogen." % name
	return ""
