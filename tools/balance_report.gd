extends SceneTree
## Balancing-Bericht: simuliert jede Rolle mehrfach offline (Standard: 5 Seeds × 8 h) und druckt
## Überleben, Leben, Vorräte, Angriffe, getötete Wölfe. Dazu ein Duell Wache gegen einen Wolf.
## Aufruf: godot --headless --path . -s tools/balance_report.gd [-- <Seeds> <Stunden>]
## Zahlen ändern in data/balance.json, data/items.json, data/roles.json – dann erneut laufen lassen.

var seeds: int = 5
var hours: float = 8.0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		seeds = int(args[0])
	if args.size() > 1:
		hours = float(args[1])
	var data := SimData.load_from_dir("res://data")
	if not data.is_valid():
		for e: String in data.errors:
			printerr(e)
		quit(1)
		return
	print("Balancing-Bericht: %d Seeds × %.0f h offline pro Rolle, Start mit 5 Beeren am Spawn" % [seeds, hours])
	print("%-12s %9s %9s %9s %9s %10s %9s %8s" % ["Rolle", "überlebt", "Leben Ø", "Beeren Ø", "Holz Ø", "angegriff.", "Wölfe †", "ms Ø"])
	for role_id: String in data.role_order:
		_report_role(data, role_id)
	_report_duel(data)
	quit()


func _report_role(data: SimData, role_id: String) -> void:
	var survived := 0
	var hp_sum := 0.0
	var berries_sum := 0
	var wood_sum := 0
	var attacked_sum := 0
	var kills_sum := 0
	var ms_sum := 0
	for seed in range(1, seeds + 1):
		var world := SimWorld.new(data, seed)
		var id := world.setup_new_game()
		var c := world.get_character(id)
		c.inventory["berries"] = 5
		world.logout(id, data.roles[role_id]["rules"], String(data.roles[role_id]["name"]))
		var started := Time.get_ticks_msec()
		world.advance(hours * 3600.0)
		ms_sum += Time.get_ticks_msec() - started
		if not c.dead:
			survived += 1
		hp_sum += c.hp
		berries_sum += int(c.inventory.get("berries", 0))
		wood_sum += int(c.inventory.get("wood", 0))
		for line: String in SimChronicle.format_all(c):
			if line.contains("angegriffen"):
				attacked_sum += 1
			if line.contains("getötet"):
				kills_sum += 1
	var n := float(seeds)
	print("%-12s %8d/%d %9.1f %9.1f %9.1f %10.1f %9.1f %8d" % [
		data.roles[role_id]["name"], survived, seeds, hp_sum / n, berries_sum / n, wood_sum / n,
		attacked_sum / n, kills_sum / n, int(ms_sum / n),
	])


## Duell: Wache (Schleuder) gegen einen Wolf, der 6 Kacheln entfernt startet. Wie oft gewinnt die Wache?
func _report_duel(data: SimData) -> void:
	var wins := 0
	var hp_left := 0.0
	for seed in range(1, seeds + 1):
		var world := SimWorld.new(data, seed)
		var id := world.setup_new_game()
		var c := world.get_character(id)
		c.pos = Vector2(20.5, 5.5)
		var wolf: SimCharacter = null
		for other: SimCharacter in world.characters.values():
			if other.kind == SimCharacter.Kind.WOLF:
				if wolf == null:
					wolf = other
				else:
					other.dead = true
		wolf.pos = c.pos + Vector2(6, 0)
		wolf.home_pos = wolf.pos
		world.logout(id, data.roles["guard"]["rules"], "Wache")
		world.advance(120.0)
		if not c.dead and (wolf.dead or wolf.ai_state == WolfAI.STATE_FLEE or wolf.pos.distance_to(c.pos) > 8.0):
			wins += 1
		hp_left += c.hp
	print("Duell Wache vs. 1 Wolf (2 min): %d/%d gewonnen, Leben Ø danach %.1f" % [wins, seeds, hp_left / float(seeds)])
