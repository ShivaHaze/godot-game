class_name SimCombat
extends RefCounted
## Kampf: Schadensrechnung als reine Logik (Richtungstreffer vorne/seitlich/hinten, flacher Rüstungsabzug – keine
## Trefferzonen, Zielen ist Positionierung) sowie Angriff, Projektile, Treffer und Tod über dem Weltzustand
## (world als erster Parameter). Spieler und Offline-NPC nutzen dasselbe System.

enum HitSide { FRONT, SIDE, BACK }


## Aus welcher Richtung kommt der Treffer? hit_dir = Flugrichtung des Treffers (vom Angreifer zum Opfer).
## Vorne: Angreifer liegt innerhalb front_arc_deg vor dem Opfer. Hinten: innerhalb back_arc_deg hinter ihm.
static func hit_side(victim_facing: Vector2, hit_dir: Vector2, front_arc_deg: float, back_arc_deg: float) -> HitSide:
	if victim_facing == Vector2.ZERO or hit_dir == Vector2.ZERO:
		return HitSide.FRONT
	var to_attacker := -hit_dir.normalized()
	var angle := absf(rad_to_deg(victim_facing.normalized().angle_to(to_attacker)))
	if angle <= front_arc_deg * 0.5:
		return HitSide.FRONT
	if angle >= 180.0 - back_arc_deg * 0.5:
		return HitSide.BACK
	return HitSide.SIDE


## Endschaden: Basis × Richtungsfaktor − (Rüstung, hinten teilweise ignoriert), mindestens min_damage.
static func damage(base: float, armor: float, side: HitSide, data: SimData) -> float:
	var multiplier := 1.0
	var effective_armor := armor
	match side:
		HitSide.SIDE:
			multiplier = data.balf("combat.side_damage_multiplier")
		HitSide.BACK:
			multiplier = data.balf("combat.back_damage_multiplier")
			effective_armor = armor * (1.0 - data.balf("combat.back_armor_ignore"))
	return maxf(data.balf("combat.min_damage"), base * multiplier - effective_armor)


static func side_name(side: HitSide) -> String:
	match side:
		HitSide.SIDE:
			return "seitlich"
		HitSide.BACK:
			return "von hinten"
	return "von vorn"


## Angriff mit der aktiven Waffe: Fernkampf schießt ein Projektil, Nahkampf schlägt zu.
static func attack(world: SimWorld, c: SimCharacter) -> void:
	var weapon: Dictionary = world.data.items.get(c.active_weapon, {})
	if weapon.is_empty():
		return
	if weapon.get("attack", "") == "ranged":
		_shoot(world, c, weapon)
	else:
		melee(world, c)


static func _shoot(world: SimWorld, c: SimCharacter, weapon: Dictionary) -> void:
	if c.fire_cooldown > 0.0 or world.projectile_count(c.id) >= int(weapon["max_projectiles"]):
		return
	if c.facing == Vector2.ZERO:
		return
	var ammo := String(weapon.get("ammo", ""))
	if not ammo.is_empty():
		if int(c.inventory.get(ammo, 0)) <= 0:
			c.fire_cooldown = float(weapon["cooldown"])  # Klicken ohne Munition: kurze Pause statt Dauerfeuer-Ereignisse
			world.events.append({"type": "no_ammo", "id": c.id, "weapon": c.active_weapon})
			return
		c.inventory[ammo] = int(c.inventory[ammo]) - 1
	var p := SimProjectile.new()
	p.owner_id = c.id
	p.pos = c.pos + c.facing * (c.collision_radius + 0.15)
	p.prev_pos = p.pos
	p.velocity = c.facing * float(weapon["projectile_speed"])
	p.damage = float(weapon["damage"])
	p.lifetime = float(weapon["projectile_lifetime"])
	world.projectiles.append(p)
	c.fire_cooldown = float(weapon["cooldown"])
	world.reveal(c)
	world.events.append({"type": "shoot", "id": c.id})
	SimCrafting.wear(world, c, c.active_weapon)


static func melee(world: SimWorld, c: SimCharacter) -> void:
	if c.bite_cooldown > 0.0 or c.melee_damage <= 0.0:
		return
	var target := nearest_enemy(world, c, c.melee_range)
	if target == null:
		# Nur Live-Spieler schlagen Bauteile (Holz) ein; NPCs und Tiere nie (nur Live kann Nehmen und Verändern)
		if c.control != SimCharacter.Controller.PLAYER or c.kind != SimCharacter.Kind.PLAYER:
			return
		var b := SimConstruction.building_in_reach(world, c, c.melee_range)
		if b == null or not SimConstruction.can_break(world, c, b):
			world.events.append({"type": "too_hard", "id": c.id, "building": b.id} if b != null else {"type": "swing", "id": c.id})
			return
		c.bite_cooldown = c.melee_cooldown
		world.reveal(c)
		SimConstruction.damage_building(world, b, c.melee_damage * world.data.balf("building.melee_damage_multiplier"), c.id)
		SimCrafting.wear(world, c, c.active_weapon)
		return
	c.bite_cooldown = c.melee_cooldown
	world.reveal(c)
	apply_damage(world, target, c.melee_damage, (target.pos - c.pos).normalized(), c.id, c.melee_effect)
	SimCrafting.wear(world, c, c.active_weapon)


## Nächster lebender, sichtbarer Charakter eines anderen Besitzers im Radius. ignore_boss: den Leitwolf auslassen
## (Offline-Charaktere greifen ihn nie zuerst an – eingeschränkte Teilnahme am Ereignis).
static func nearest_enemy(world: SimWorld, c: SimCharacter, radius: float, ignore_boss: bool = false) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for other: SimCharacter in world.spatial.query(c.pos, radius):
		if other == c or other.dead or other.hidden or world.allied(other.owner_id, c.owner_id) or (ignore_boss and other.boss):
			continue
		var d := other.pos.distance_squared_to(c.pos)
		if d <= best_d:
			best_d = d
			best = other
	return best


static func update_projectiles(world: SimWorld, dt: float) -> void:
	var i := 0
	while i < world.projectiles.size():
		var p: SimProjectile = world.projectiles[i]
		var removed := false
		var steps := maxi(1, ceili(p.velocity.length() * dt / SimMap.MOVE_SUBSTEP))
		var part := p.velocity * dt / float(steps)
		for s in steps:
			p.pos += part
			if not world.map.is_walkable(SimMap.cell_of(p.pos)) or world.map.building_at(p.pos) != null or world.in_peace_zone(p.pos):
				world.events.append({"type": "projectile_wall", "pos": p.pos})
				removed = true
				break
			var victim := _projectile_victim(world, p)
			if victim != null:
				apply_damage(world, victim, p.damage, p.velocity.normalized(), p.owner_id)
				removed = true
				break
		p.lifetime -= dt
		if p.lifetime <= 0.0:
			removed = true
		if removed:
			world.projectiles.remove_at(i)
		else:
			i += 1


static func _projectile_victim(world: SimWorld, p: SimProjectile) -> SimCharacter:
	for c: SimCharacter in world.spatial.query(p.pos, 1.0):
		if c.dead or c.hidden or c.id == p.owner_id:
			continue
		var r := c.collision_radius + 0.1
		if c.pos.distance_squared_to(p.pos) < r * r:
			return c
	return null


## Fügt Schaden mit Richtungstreffer zu. hit_dir = Flugrichtung des Treffers (Angreifer -> Opfer).
static func apply_damage(world: SimWorld, victim: SimCharacter, base_damage: float, hit_dir: Vector2, attacker_id: int, effect: String = "", attacker_label: String = "") -> Dictionary:
	var peace_attacker := world.get_character(attacker_id)
	if world.in_peace_zone(victim.pos) or (peace_attacker != null and world.in_peace_zone(peace_attacker.pos)):
		world.events.append({"type": "market_peace", "id": victim.id, "attacker": attacker_id, "pos": victim.pos})
		return {}
	var side := SimCombat.hit_side(victim.facing, hit_dir, world.data.balf("combat.front_arc_degrees"), world.data.balf("combat.back_arc_degrees"))
	var amount := SimCombat.damage(base_damage, victim.armor, side, world.data)
	victim.hp = maxf(0.0, victim.hp - amount)
	var armor_item := SimCrafting.armor_item_of(world, victim)
	if not armor_item.is_empty():
		SimCrafting.wear(world, victim, armor_item)
	victim.last_damage_time = world.time
	victim.last_attacker_id = attacker_id
	world.reveal(victim)
	var attacker := world.get_character(attacker_id)
	var event := {"type": "hit", "id": victim.id, "attacker": attacker_id, "damage": amount, "side": side, "pos": victim.pos, "known": attacker != null and world.knows_name(victim, attacker)}
	world.events.append(event)
	if victim.hp <= 0.0:
		kill(world, victim, attacker_id, "", attacker_label)
	elif not effect.is_empty():
		SimEffects.apply_effect(world, victim, effect, attacker_id)
	return event


static func kill(world: SimWorld, victim: SimCharacter, attacker_id: int, cause: String = "", attacker_label: String = "") -> void:
	victim.dead = true
	victim.hp = 0.0
	victim.hidden = false
	victim.effects.clear()
	victim.death_time = world.time
	var attacker := world.get_character(attacker_id)
	var attacker_name := world.describe(victim, attacker) if attacker != null else (attacker_label if not attacker_label.is_empty() else "Unbekannt")
	world.events.append({"type": "death", "id": victim.id, "attacker": attacker_id, "cause": cause})
	if victim.boss:
		world.events.append({"type": "boss_killed", "id": victim.id, "attacker": attacker_id, "name": victim.name})
	if victim.kind == SimCharacter.Kind.PLAYER:
		SimChronicle.add(world, victim, ("%s, zuletzt getroffen von %s" % [cause, attacker_name]) if not cause.is_empty() else "gestorben durch %s" % attacker_name)
	if attacker != null and attacker.kind == SimCharacter.Kind.PLAYER and attacker.control == SimCharacter.Controller.RULES:
		SimChronicle.add(world, attacker, "%s getötet" % world.describe(attacker, victim))
