class_name SimEffects
extends RefCounted
## Zustandseffekte (Blutung, Vergiftung, Krankheit): ignorieren Rüstung, je eine Quelle und ein Gegenmittel (Design).
## Zahlen in balance.json `effects`. Reine Logik über dem Weltzustand (world als erster Parameter).


static func has_effect(world: SimWorld, c: SimCharacter, effect: String) -> bool:
	return float(c.effects.get(effect, -1e9)) > world.time


const EFFECT_NAMES: Dictionary = {"bleeding": "blutet", "poison": "vergiftet", "sick": "erkrankt"}


## Verlangsamung durch laufende Effekte (Krankheit), zusätzlich zur Rüstung.
static func effect_slow(world: SimWorld, c: SimCharacter) -> float:
	var slow := 0.0
	for effect: String in c.effects:
		if has_effect(world, c, effect):
			slow = maxf(slow, float(world.data.balance["effects"][effect].get("slow", 0.0)))
	return slow


static func effect_hunger_multiplier(world: SimWorld, c: SimCharacter) -> float:
	var factor := 1.0
	for effect: String in c.effects:
		if has_effect(world, c, effect):
			factor *= float(world.data.balance["effects"][effect].get("hunger_multiplier", 1.0))
	return factor


## Effekt anlegen oder verlängern; ignoriert Rüstung. Ereignis und Chronik nur beim Beginn.
static func apply_effect(world: SimWorld, c: SimCharacter, effect: String, attacker_id: int) -> void:
	if c.dead or not world.data.balance.get("effects", {}).has(effect):
		return
	var fresh := not has_effect(world, c, effect)
	c.effects[effect] = world.time + world.data.balf("effects.%s.duration" % effect)
	if not fresh:
		return
	world.events.append({"type": "effect", "id": c.id, "effect": effect, "attacker": attacker_id})
	if c.kind == SimCharacter.Kind.PLAYER and c.control == SimCharacter.Controller.RULES:
		SimChronicle.add(world, c, String(EFFECT_NAMES.get(effect, effect)))


## Laufende Effekte: Blutung zieht Leben ohne Rüstung ab und kann töten ("verblutet").
static func update_effects(world: SimWorld, c: SimCharacter, dt: float) -> void:
	var zone_effect := String(world.zone_at(c.pos).get("effect", ""))
	if not zone_effect.is_empty():
		apply_effect(world, c, zone_effect, -1)  # Sumpf: solange man drin steht
	if c.effects.is_empty():
		return
	for effect: String in c.effects.keys():
		if float(c.effects[effect]) <= world.time:
			c.effects.erase(effect)
			world.events.append({"type": "effect_ended", "id": c.id, "effect": effect})
			continue
		var dps := world.data.balf("effects.%s.damage_per_second" % effect)
		if dps > 0.0:
			c.hp = maxf(0.0, c.hp - dps * dt)
			if c.hp <= 0.0:
				SimCombat.kill(world, c, c.last_attacker_id, "verblutet" if effect == "bleeding" else "an Gift gestorben")
				return
