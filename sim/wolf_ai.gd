class_name WolfAI
extends RefCounted
## Wolf-Verhalten als PvE-Druck: streunt um seinen Spawn, greift sichtbare Charaktere in Reichweite an,
## beißt im Nahkampf, flieht bei wenig Leben und erholt sich danach. Erzeugt nur Absichten (SimIntent).

const STATE_WANDER: String = "wander"
const STATE_CHASE: String = "chase"
const STATE_FLEE: String = "flee"


static func decide(world: SimWorld, wolf: SimCharacter, dt: float) -> SimIntent:
	var intent := SimIntent.new()
	var data := world.data
	wolf.ai_timer -= dt
	var search_radius := data.balf("wolf.give_up_radius") if wolf.ai_state == STATE_CHASE else data.balf("wolf.aggro_radius")
	var target := nearest_prey(world, wolf, search_radius)

	if wolf.ai_state != STATE_FLEE and target != null and wolf.health_percent() < data.balf("wolf.flee_hp_percent"):
		wolf.ai_state = STATE_FLEE
		wolf.ai_timer = data.balf("wolf.flee_duration")

	match wolf.ai_state:
		STATE_FLEE:
			if wolf.ai_timer <= 0.0:
				wolf.ai_state = STATE_WANDER
				wolf.ai_timer = 0.0
			else:
				var threat := target if target != null else world.get_character(wolf.last_attacker_id)
				if threat != null and threat.pos != wolf.pos:
					intent.move = (wolf.pos - threat.pos).normalized()
					intent.aim = intent.move  # rennt weg, zeigt den Rücken
				else:
					_wander(world, wolf, intent)
		STATE_CHASE:
			if target == null:
				wolf.ai_state = STATE_WANDER
				wolf.ai_timer = 0.0
			else:
				intent.aim = target.pos - wolf.pos
				if wolf.pos.distance_to(target.pos) <= wolf.melee_range:
					intent.melee = true
				else:
					intent.move = SimNav.direction_toward(world, wolf, target.pos, dt, wolf.melee_range * 0.8)
		_:
			if target != null:
				wolf.ai_state = STATE_CHASE
				intent.aim = target.pos - wolf.pos
			else:
				_wander(world, wolf, intent)
	return intent


## Nächster lebender, sichtbarer Spielercharakter (live oder NPC) im Radius.
static func nearest_prey(world: SimWorld, wolf: SimCharacter, radius: float) -> SimCharacter:
	var best: SimCharacter = null
	var best_d := radius * radius
	for c: SimCharacter in world.spatial.query(wolf.pos, radius):
		if c.kind != SimCharacter.Kind.PLAYER or c.dead or c.hidden or world.in_peace_zone(c.pos):
			continue
		var d := c.pos.distance_squared_to(wolf.pos)
		if d <= best_d:
			best_d = d
			best = c
	return best


static func _wander(world: SimWorld, wolf: SimCharacter, intent: SimIntent) -> void:
	var r := world.data.balf("wolf.wander_radius")
	if wolf.ai_timer <= 0.0 or wolf.pos.distance_to(wolf.ai_target_pos) < 0.4:
		wolf.ai_target_pos = wolf.home_pos + Vector2(world.rng.randf_range(-r, r), world.rng.randf_range(-r, r))
		wolf.ai_timer = world.rng.randf_range(2.0, 5.0)
	var to_target := wolf.ai_target_pos - wolf.pos
	if to_target.length() > 0.4:
		intent.move = to_target.normalized() * 0.5  # gemächlich
