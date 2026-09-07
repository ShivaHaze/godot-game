class_name SimCombat
extends RefCounted
## Schadensrechnung als reine Logik: Richtungstreffer (vorne/seitlich/hinten) und flacher Rüstungsabzug.
## Keine Trefferzonen – Zielen ist Positionierung.

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
