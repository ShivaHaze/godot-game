extends SceneTree
## Bot-Clients (Netzwerk-Spike, Teil 2): N ENet-Clients in einem headless Prozess. Jeder Bot läuft zufällig
## umher, schießt gelegentlich, isst bei Hunger, loggt sich nach einer Weile mit einer zufälligen Rolle aus
## (Verbindung trennen) und kommt später zurück (einloggen in den eigenen NPC).
## Aufruf: godot --headless --path . -s tools/bot_clients.gd [-- <Anzahl> <Host> <Port> <Laufzeit s>]
## Standard: 50 127.0.0.1 7777 60. Statistik alle 5 s.

var count: int = 50
var host: String = "127.0.0.1"
var port: int = 7777
var run_seconds: float = 60.0

var data: SimData
var bots: Array[Dictionary] = []   # {client, dir, dir_timer, phase, phase_timer, index}
var rng := RandomNumberGenerator.new()
var _last_usec: int = 0
var _tick_accumulator: float = 0.0
var _stats_timer: float = 0.0
var _elapsed: float = 0.0
var _total_bytes: int = 0
var _total_snapshots: int = 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		count = int(args[0])
	if args.size() > 1:
		host = args[1]
	if args.size() > 2:
		port = int(args[2])
	if args.size() > 3:
		run_seconds = float(args[3])
	data = SimData.load_from_dir("res://data")
	rng.seed = 99
	for i in count:
		var client := NetClient.new()
		if client.connect_to(data, host, port, "bot%02d" % i) != OK:
			printerr("Bot %d: Verbindung fehlgeschlagen" % i)
			continue
		bots.append({
			"client": client, "dir": Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU)), "dir_timer": rng.randf_range(1.0, 3.0),
			"phase": "online", "phase_timer": rng.randf_range(15.0, 40.0), "index": i,
		})
	Engine.max_fps = 60
	_last_usec = Time.get_ticks_usec()
	process_frame.connect(_on_frame)
	print("%d Bots verbinden sich mit %s:%d für %.0f s …" % [bots.size(), host, port, run_seconds])


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var delta := minf((now - _last_usec) / 1_000_000.0, 0.25)
	_last_usec = now
	for bot: Dictionary in bots:
		var client: NetClient = bot["client"]
		client.poll()
		client.messages.clear()
	_tick_accumulator += delta
	while _tick_accumulator >= 0.05:
		_tick_accumulator -= 0.05
		for bot: Dictionary in bots:
			_bot_tick(bot, 0.05)
	_elapsed += delta
	_stats_timer += delta
	if _stats_timer >= 5.0:
		_print_stats(_stats_timer)
		_stats_timer = 0.0
	if _elapsed >= run_seconds:
		_print_stats(maxf(_stats_timer, 0.001))
		print("Bots: fertig. Gesamt empfangen %.1f MB in %d Snapshots." % [_total_bytes / 1048576.0, _total_snapshots])
		for bot: Dictionary in bots:
			bot["client"].disconnect_from_server()
		quit()


func _bot_tick(bot: Dictionary, dt: float) -> void:
	var client: NetClient = bot["client"]
	bot["phase_timer"] -= dt
	match String(bot["phase"]):
		"online":
			if not client.joined:
				return
			bot["dir_timer"] -= dt
			if bot["dir_timer"] <= 0.0:
				bot["dir"] = Vector2.RIGHT.rotated(rng.randf_range(0.0, TAU))
				bot["dir_timer"] = rng.randf_range(1.0, 3.0)
			var intent := SimIntent.new()
			intent.move = bot["dir"]
			intent.aim = bot["dir"]
			intent.shoot = rng.randf() < 0.03
			intent.interact = rng.randf() < 0.2
			var me := client.me()
			intent.eat = me != null and me.hunger < 30.0
			client.send_intent(intent)
			if bot["phase_timer"] <= 0.0:
				var role: String = data.role_order[rng.randi_range(0, data.role_order.size() - 1)]
				client.send({"t": "logout", "rules": data.roles[role]["rules"], "role": role}, true)
				bot["phase"] = "leaving"
				bot["phase_timer"] = 0.5
		"leaving":
			if bot["phase_timer"] <= 0.0:
				client.disconnect_from_server()
				bot["phase"] = "offline"
				bot["phase_timer"] = rng.randf_range(10.0, 25.0)
		"offline":
			if bot["phase_timer"] <= 0.0:
				client.connect_to(data, host, port, "bot%02d" % int(bot["index"]))
				bot["phase"] = "online"
				bot["phase_timer"] = rng.randf_range(15.0, 40.0)


func _print_stats(interval: float) -> void:
	var connected := 0
	var joined := 0
	var bytes := 0
	var snapshots := 0
	var chars := 0
	for bot: Dictionary in bots:
		var client: NetClient = bot["client"]
		if client.connected:
			connected += 1
		if client.joined:
			joined += 1
			chars += client.chars_in_last_snapshot
		bytes += client.bytes_in
		snapshots += client.snapshots_in
		client.bytes_in = 0
		client.snapshots_in = 0
	_total_bytes += bytes
	_total_snapshots += snapshots
	print("Bots %.0f s: verbunden %d · beigetreten %d · rein %.1f KB/s · %d Snapshots/s · Ø %.0f Charaktere je Snapshot" % [
		_elapsed, connected, joined, bytes / 1024.0 / interval, int(snapshots / interval), float(chars) / maxf(1.0, joined),
	])
