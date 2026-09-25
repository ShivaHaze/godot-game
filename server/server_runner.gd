class_name ServerRunner
extends RefCounted
## Betreibt den autoritativen Server: Welt laden oder neu anlegen, NPC-Füllung (nur bei neuer Welt), Tick über NetServer, Statistik,
## regelmäßiges Speichern in SQLite (WorldStore), Konten (AccountDbStore), tägliche Sicherung. Wird vom
## Skript-Einstieg (server/server_main.gd, `-s`) und vom exportierten Programm (game/boot.gd mit --server) gleich
## benutzt. Keine Nodes; der Aufrufer treibt update(delta) je Frame.

const WORLD_DB: String = "world.db"
const ACCOUNTS_DB: String = "accounts.db"
const LEGACY_SAVE: String = "server_save.dat"      # Spielstand vor Schritt 52, wird einmalig übernommen
const LEGACY_DONE_SUFFIX: String = ".uebernommen"  # danach so umbenannt: eine beiseitegelegte world.db heißt neue Welt
const LEGACY_ACCOUNTS: String = "accounts.dat"     # Konten vor Schritt 52, werden einmalig übernommen
const BACKUP_DIR: String = "backups"
const BACKUP_KEEP: int = 7
const STATS_INTERVAL: float = 5.0
const SAVE_INTERVAL: float = 10.0                  # nur geänderte Zeilen, daher günstig
const FILL_SPAWN_DISTANCE: float = 6.0             # Füll-NPCs mindestens so viele Kacheln von jedem Spieler-Spawn
const FILL_SPACING: float = 5.0                    # Füll-NPCs möglichst so viele Kacheln voneinander
const FILL_SKIP_ROLES: Array[String] = ["trader"]  # Füll-NPCs ohne Händler (läuft mit voller Ladung quer über die Karte)
const RESTART_NOTE: String = "Server-Neustart"     # steht in der Chronik von Charakteren, die beim Stopp live waren

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
var world_created: bool = false    # true = diese Welt wurde bei diesem Start neu angelegt (nur dann wird gefüllt)

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
	if world_created:
		var fillers := spawn_fillers(world, fill_npcs)
		if fill_npcs > 0:
			print("Füll-NPCs: %d von %d gesetzt (nur bei neuer Welt)." % [fillers.size(), fill_npcs])
	else:
		var orphans := logout_orphans(world)
		if orphans > 0:
			print("%d Charaktere waren beim Stopp live und handeln jetzt nach ihren Regeln (%s)." % [orphans, RESTART_NOTE])
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
		var legacy := data_dir.path_join(LEGACY_SAVE)
		if not store.has_world() and store.import_legacy(data, legacy):
			# Umbenennen: wer später world.db beiseitelegt, will eine neue Welt – nicht die von vor Schritt 52 zurück
			DirAccess.rename_absolute(legacy, legacy + LEGACY_DONE_SUFFIX)
			print("Alter Spielstand übernommen: %s → %s (die alte Datei heißt jetzt %s%s)" % [LEGACY_SAVE, WORLD_DB, LEGACY_SAVE, LEGACY_DONE_SUFFIX])
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
	world_created = true
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


## Nach einem Neustart: wer beim Stopp live war (Steuerung PLAYER), hat keine Verbindung mehr und stünde ohne Regeln
## herum, bis er verhungert. Solche Charaktere loggen aus wie beim Trennen – mit ihren eigenen Regeln (leer: Standardregeln);
## die Chronik beginnt mit "ausgeloggt als <Rolle> (Server-Neustart)". Rückgabe: Anzahl.
static func logout_orphans(p_world: SimWorld) -> int:
	var count := 0
	for c: SimCharacter in p_world.characters.values():
		if c.kind != SimCharacter.Kind.PLAYER or c.dead or c.control != SimCharacter.Controller.PLAYER:
			continue
		var rules: Array = c.rules if not c.rules.is_empty() else p_world.data.default_rules
		var role_name := String(p_world.data.roles.get(c.role_id, {}).get("name", "eigene Regeln"))
		p_world.logout(c.id, rules, "%s (%s)" % [role_name, RESTART_NOTE])
		count += 1
	return count


## Füll-NPCs für eine neue Welt: Offline-Siedler mit 5 Beeren, Rollen reihum aus role_order ohne FILL_SKIP_ROLES, ohne
## Übergang. Sie stehen auf freiem Boden (Kachel "floor"), nicht in einer Zone (Markt, Outpost, Sumpf), nicht auf einem
## Claim, mindestens FILL_SPAWN_DISTANCE Kacheln von jedem Spieler-Spawn – dort erscheinen die echten Spieler –,
## außerhalb von wolf.aggro_radius um jeden Wolf-Spawn und außerhalb des Leitwolf-Reviers (filler_cells). Jede Zelle
## höchstens einmal, möglichst FILL_SPACING Kacheln voneinander (Fremde nebeneinander: ein Querschläger auf den Wolf
## löst Gegenwehr aus – Messung Schritt 55: vier Füll-NPCs auf 3 Kacheln, einer erschoss den anderen). Nur bei neuer
## Welt (vorher füllte jeder Start bis zur Zielzahl auf und legte mit jedem Update neue Beute in die Welt). Auch
## tools/playtest_sim.gd setzt sie so. Rückgabe: die neuen NPCs.
static func spawn_fillers(p_world: SimWorld, count: int, rng_seed: int = 7) -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	var p_data := p_world.data
	var roles: Array[String] = []
	for role: String in p_data.role_order:
		if not FILL_SKIP_ROLES.has(role):
			roles.append(role)
	var cells := filler_cells(p_world)
	if count <= 0 or roles.is_empty() or cells.is_empty():
		return result
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var free: Array[Vector2i] = cells.duplicate()
	var spaced: Array[Vector2i] = cells.duplicate()  # freie Zellen mit FILL_SPACING Abstand zu allen gesetzten
	for i in count:
		if free.is_empty():
			free.assign(cells)
		var pool := spaced if not spaced.is_empty() else free
		var cell: Vector2i = pool[rng.randi_range(0, pool.size() - 1)]
		free.erase(cell)
		var still: Array[Vector2i] = []
		for candidate: Vector2i in spaced:
			if Vector2(candidate).distance_to(Vector2(cell)) >= FILL_SPACING:
				still.append(candidate)
		spaced = still
		var c := p_world.spawn_player(SimMap.cell_center(cell), "füll%d" % i, "Siedler %d" % i)
		c.inventory["berries"] = 5
		var role: String = roles[i % roles.size()]
		c.role_id = role
		p_world.logout(c.id, p_data.roles[role]["rules"], String(p_data.roles[role]["name"]))
		c.logout_time = -1e9
		result.append(c)
	return result


## Zellen, auf denen Füll-NPCs stehen dürfen (siehe spawn_fillers). Wolf-Spawns und Leitwolf-Revier meiden: Review Schritt 55 – auf der
## Standardkarte standen mit Seed 7 zwei der drei Wachen im Leitwolf-Revier (eine 1,4 Kacheln von seinem Spawn) und die
## dritte 1 Kachel neben einem Wolf-Spawn; alle drei waren nach 2 h tot. Bleibt dann nichts übrig (sehr kleine Karte),
## zählen Wolf-Spawns und Revier nicht.
static func filler_cells(p_world: SimWorld) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var near_wolves: Array[Vector2i] = []
	var wolf_distance := p_world.data.balf("wolf.aggro_radius")
	var boss_home := SimEvents.boss_home_cell(p_world)
	var territory := p_world.data.balf("events.boss.territory_radius")
	var map := p_world.map
	for y in map.height:
		for x in map.width:
			var cell := Vector2i(x, y)
			if map.tile_id(cell) != "floor" or not map.zone(cell).is_empty() or not map.is_walkable_for(cell, "", p_world.data):
				continue
			if p_world.claims.claim_at(cell) != null:
				continue
			var near_spawn := false
			for spawn: Vector2i in p_world.data.player_spawns:
				if Vector2(cell).distance_to(Vector2(spawn)) < FILL_SPAWN_DISTANCE:
					near_spawn = true
					break
			if near_spawn:
				continue
			var near_wolf := boss_home.x >= 0 and Vector2(cell).distance_to(Vector2(boss_home)) <= territory
			for spawn: Vector2i in p_world.data.wolf_spawns:
				if Vector2(cell).distance_to(Vector2(spawn)) <= wolf_distance:
					near_wolf = true
					break
			if near_wolf:
				near_wolves.append(cell)
			else:
				result.append(cell)
	return result if not result.is_empty() else near_wolves
