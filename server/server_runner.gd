class_name ServerRunner
extends RefCounted
## Betreibt den autoritativen Server: Welt laden oder neu anlegen, NPC-Füllung, Tick über NetServer, Statistik,
## regelmäßiges Speichern in SQLite (WorldStore), Konten (AccountDbStore), tägliche Sicherung. Wird vom
## Skript-Einstieg (server/server_main.gd, `-s`) und vom exportierten Programm (game/boot.gd mit --server) gleich
## benutzt. Keine Nodes; der Aufrufer treibt update(delta) je Frame.

const WORLD_DB: String = "world.db"
const ACCOUNTS_DB: String = "accounts.db"
const LEGACY_SAVE: String = "server_save.dat"      # Spielstand vor Schritt 52, wird einmalig übernommen
const LEGACY_ACCOUNTS: String = "accounts.dat"     # Konten vor Schritt 52, werden einmalig übernommen
const BACKUP_DIR: String = "backups"
const BACKUP_KEEP: int = 7
const STATS_INTERVAL: float = 5.0
const SAVE_INTERVAL: float = 10.0                  # nur geänderte Zeilen, daher günstig

var port: int = 7777
var data_dir: String = "user://"   # Ordner für world.db, accounts.db, backups/; leer = nur im Speicher (Tests)
var use_accounts: bool = true      # false = offener Server ohne Passwörter ('open')
var fill_npcs: int = 0
var run_seconds: float = 0.0
var map_arg: String = ""

var data: SimData
var world: SimWorld
var server := NetServer.new()
var store: WorldStore = null
var account_store: AccountDbStore = null
var running: bool = false

var _stats_timer: float = 0.0
var _save_timer: float = 0.0
var _elapsed: float = 0.0


## Argumente in der Reihenfolge <Port> <NPC-Füllung> <Laufzeit s> <Karte>; Karte = Pfad zu einer map.json oder
## 'gen:120x90:7' (Generator mit Breite×Höhe:Seed), leer = data/map.json. Das Wort 'open' an beliebiger Stelle
## macht den Server passwortfrei (Bots, Rauchtests); ohne es braucht jeder Beitritt ein Passwort (Konten).
func configure(args: PackedStringArray) -> void:
	var positional := PackedStringArray()
	for arg: String in args:
		if arg == "open":
			use_accounts = false
		else:
			positional.append(arg)
	if positional.size() > 0:
		port = int(positional[0])
	if positional.size() > 1:
		fill_npcs = int(positional[1])
	if positional.size() > 2:
		run_seconds = float(positional[2])
	if positional.size() > 3:
		map_arg = positional[3]


## Welt laden oder anlegen, Konten öffnen und den Port öffnen. Rückgabe OK oder der Fehler (Meldung auf der Konsole).
func start() -> Error:
	data = SimData.load_from_dir("res://data")
	if not data.is_valid():
		for e: String in data.errors:
			printerr(e)
		return ERR_INVALID_DATA
	if not map_arg.is_empty():
		var problems := data.apply_map(_load_map_arg(map_arg))
		if not problems.is_empty():
			printerr("Karte unbrauchbar: ", problems)
			return ERR_INVALID_DATA
		print("Karte: %s (%d×%d, %d Spieler-Spawns)" % [map_arg, data.map_width, data.map_height, data.player_spawns.size()])
	var err := _open_world()
	if err != OK:
		return err
	_fill_npcs()
	_open_accounts()
	err = server.start(data, world, port)
	if err != OK:
		return err
	running = true
	print("Server läuft auf Port %d (Tick %d Hz, Snapshots %d Hz). Strg+C beendet." % [port, data.bali("tick_rate"), data.bali("tick_rate") / NetProtocol.SNAPSHOT_EVERY_TICKS])
	return OK


## Ein Frame: Netzwerk und Sim weiterrechnen, Statistik und Speichern nach Zeit. false, wenn die Laufzeit erreicht ist.
func update(delta: float) -> bool:
	if not running:
		return false
	delta = minf(delta, 0.25)
	server.update(delta)
	_elapsed += delta
	_stats_timer += delta
	_save_timer += delta
	if _stats_timer >= STATS_INTERVAL:
		print(server.stats_line(_stats_timer))
		_stats_timer = 0.0
	if _save_timer >= SAVE_INTERVAL:
		_save_timer = 0.0
		save()
	if run_seconds > 0.0 and _elapsed >= run_seconds:
		print("Laufzeit erreicht, speichere und beende.")
		stop()
		return false
	return true


## Geänderte Zeilen in die Datenbank schreiben; einmal am Tag eine Sicherungskopie.
func save() -> void:
	if world == null or store == null:
		return
	if store.save(world) != OK:
		printerr("Speichern fehlgeschlagen: ", store.path)
		return
	var today := Time.get_date_string_from_system(true)
	if store.meta_value("last_backup_day") != today:
		var target := store.backup(data_dir.path_join(BACKUP_DIR), BACKUP_KEEP)
		if not target.is_empty():
			store.set_meta_value("last_backup_day", today)
			print("Sicherung: ", target)


## Speichern, Datenbanken schließen und Port schließen (auch bei Strg+C / Fensterschluss).
func stop() -> void:
	if not running:
		return
	running = false
	save()
	server.stop()
	if store != null:
		store.close()
	if account_store != null:
		account_store.close()


## Welt aus world.db laden; ohne Datenbank den alten Spielstand übernehmen oder eine neue Welt anlegen.
func _open_world() -> Error:
	if not data_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(data_dir)
		store = WorldStore.new()
		if store.open(data_dir.path_join(WORLD_DB)) != OK:
			return ERR_CANT_OPEN
		if not store.has_world() and store.import_legacy(data, data_dir.path_join(LEGACY_SAVE)):
			print("Alter Spielstand übernommen: %s → %s" % [LEGACY_SAVE, WORLD_DB])
		if store.has_world():
			world = store.load_world(data)
			if world == null:
				printerr("Datenbank unlesbar: ", store.path)
				return ERR_INVALID_DATA
			print("Welt geladen: Uhr %s, %d Charaktere, %d Bauteile (%s)." % [world.clock_string(), world.characters.size(), world.map.buildings.size(), store.path])
			return OK
	world = SimWorld.new(data, int(Time.get_unix_time_from_system()) % 100000)
	world.setup_new_game()
	world.characters.erase(1)  # der lokale 'Du'-Charakter gehört auf dem Server niemandem
	print("Neue Welt.")
	return OK


## Konten: Datenbank neben der Welt, alte Kontodatei einmalig übernehmen; ohne Ordner nur im Speicher.
func _open_accounts() -> void:
	if not use_accounts:
		print("Offener Server: keine Passwörter (Bots, Tests).")
		return
	if data_dir.is_empty():
		server.accounts = Accounts.new(Accounts.AccountStore.new())
	else:
		account_store = AccountDbStore.new(data_dir.path_join(ACCOUNTS_DB))
		var imported := account_store.import_legacy(data_dir.path_join(LEGACY_ACCOUNTS))
		if imported > 0:
			print("Alte Konten übernommen: %d (%s → %s)" % [imported, LEGACY_ACCOUNTS, ACCOUNTS_DB])
		server.accounts = Accounts.new(account_store)
	print("Konten: %d bekannt, Passwörter erforderlich." % server.accounts.count())


## 'gen:BxH:Seed' oder Pfad zu einer map.json.
func _load_map_arg(arg: String) -> Dictionary:
	if arg.begins_with("gen:"):
		var parts := arg.split(":")
		var size := parts[1].split("x") if parts.size() > 1 else PackedStringArray(["120", "90"])
		var seed := int(parts[2]) if parts.size() > 2 else 1
		return MapGen.generate(int(size[0]), int(size[1]) if size.size() > 1 else 90, seed)
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(arg)) != OK or not (json.data is Dictionary):
		return {}
	return json.data


## Offline-Siedler bis zur Zielzahl auffüllen (ein geladener Spielstand bringt seine schon mit).
func _fill_npcs() -> void:
	if fill_npcs <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var walkable: Array[Vector2i] = []
	for y in world.map.height:
		for x in world.map.width:
			if world.map.is_walkable(Vector2i(x, y)):
				walkable.append(Vector2i(x, y))
	var existing := 0
	for other: SimCharacter in world.characters.values():
		if other.kind == SimCharacter.Kind.PLAYER and not other.dead and other.owner_id.begins_with("füll"):
			existing += 1
	for i in range(existing, fill_npcs):
		var cell: Vector2i = walkable[rng.randi_range(0, walkable.size() - 1)]
		var c := world.spawn_player(SimMap.cell_center(cell), "füll%d" % i, "Siedler %d" % i)
		c.inventory["berries"] = 5
		var role: String = data.role_order[i % data.role_order.size()]
		world.logout(c.id, data.roles[role]["rules"], String(data.roles[role]["name"]))
		c.logout_time = -1e9
