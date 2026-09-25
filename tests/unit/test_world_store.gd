extends GutTest
## Persistenz in SQLite: exakter Kreislauf, nur geänderte Zeilen, Übernahme alter Spielstände, Sicherungen, Konten.

const DIR: String = "user://test_store"
const PORT: int = 7815

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")
	_wipe()


func after_each() -> void:
	_wipe()


func _wipe() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for sub: String in DirAccess.get_directories_at(DIR):
		for name: String in DirAccess.get_files_at(DIR.path_join(sub)):
			DirAccess.remove_absolute(DIR.path_join(sub).path_join(name))
		DirAccess.remove_absolute(DIR.path_join(sub))
	for name: String in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(name))
	DirAccess.remove_absolute(DIR)


func _busy_world(seed: int) -> SimWorld:
	var world := SimWorld.new(data, seed)
	var id := world.setup_new_game()
	var player := world.get_character(id)
	player.inventory["berries"] = 6
	player.inventory["wood"] = 2
	world.add_marker(id)
	world.spawn_building("wood_wall", world.map.nearest_free_cell(SimMap.cell_of(player.pos) + Vector2i(2, 0), "p1", data), "p1")
	world.logout(id, data.roles["gatherer"]["rules"], "Sammler")
	world.advance(300.0)
	return world


func _snapshot(world: SimWorld) -> Dictionary:
	var dict := SimSave.world_to_dict(world)
	dict.erase("projectiles")
	return dict


func _open(name: String = "world.db") -> WorldStore:
	DirAccess.make_dir_recursive_absolute(DIR)
	var store := WorldStore.new()
	assert_eq(store.open(DIR.path_join(name)), OK)
	return store


func test_schema_is_created_with_version() -> void:
	var store := _open()
	assert_eq(store.meta_value("schema_version"), str(WorldStore.SCHEMA_VERSION))
	assert_false(store.has_world())
	assert_eq(store.row_count("characters"), 0)
	store.close()
	assert_true(FileAccess.file_exists(DIR.path_join("world.db")))


func test_roundtrip_is_exact_and_continues_identically() -> void:
	var world := _busy_world(4)
	var store := _open()
	assert_eq(store.save(world), OK)
	assert_eq(store.row_count("characters"), world.characters.size())
	assert_eq(store.row_count("buildings"), world.map.buildings.size())
	assert_eq(store.row_count("nodes"), world.map.nodes.size())
	store.close()
	var again := _open()
	var loaded := again.load_world(data)
	assert_not_null(loaded)
	assert_eq_deep(SimSave.world_to_dict(loaded), SimSave.world_to_dict(world))
	world.advance(1800.0)
	loaded.advance(1800.0)
	assert_eq_deep(_snapshot(loaded), _snapshot(world))
	again.close()


func test_only_changed_rows_are_written() -> void:
	var world := _busy_world(5)
	var store := _open()
	assert_eq(store.save(world), OK)
	var first := store.last_written
	assert_gt(first, world.characters.size(), "erstes Mal: alles")
	assert_eq(store.save(world), OK)
	assert_eq(store.last_written, 0, "nichts geändert: nichts geschrieben")
	assert_eq(store.last_deleted, 0)
	world.get_character(1).pos += Vector2(0.5, 0)
	assert_eq(store.save(world), OK)
	assert_eq(store.last_written, 1, "ein Charakter bewegt: eine Zeile")
	var wolf_id := -1
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.WOLF:
			wolf_id = c.id
			break
	assert_gt(wolf_id, 0)
	world.characters.erase(wolf_id)
	var building_id: int = world.map.buildings.keys()[0]
	world.map.buildings.erase(building_id)
	assert_eq(store.save(world), OK)
	assert_eq(store.last_deleted, 2, "verschwundener Wolf und Bauteil werden gelöscht")
	assert_eq(store.row_count("characters"), world.characters.size())
	assert_eq(store.row_count("buildings"), world.map.buildings.size())
	store.close()
	var again := _open()
	var loaded := again.load_world(data)
	assert_false(loaded.characters.has(wolf_id))
	assert_eq_deep(SimSave.world_to_dict(loaded), SimSave.world_to_dict(world))
	again.close()


func test_legacy_save_is_imported_once() -> void:
	var world := _busy_world(6)
	DirAccess.make_dir_recursive_absolute(DIR)
	var legacy := DIR.path_join("server_save.dat")
	assert_eq(SimSave.save_to_file(world, legacy), OK)
	var store := _open()
	assert_true(store.import_legacy(data, legacy))
	assert_true(store.has_world())
	assert_eq_deep(SimSave.world_to_dict(store.load_world(data)), SimSave.world_to_dict(world))
	assert_false(store.import_legacy(data, legacy), "zweites Mal: nicht überschreiben")
	assert_false(store.import_legacy(data, DIR.path_join("fehlt.dat")))
	store.close()


func test_backup_is_loadable_and_rotates() -> void:
	var world := _busy_world(7)
	var store := _open()
	assert_eq(store.save(world), OK)
	var backups := DIR.path_join("backups")
	assert_ne(store.backup(backups, 2, "a"), "")
	assert_ne(store.backup(backups, 2, "b"), "")
	var third := store.backup(backups, 2, "c")
	assert_eq(third, backups.path_join("world-c.db"))
	assert_eq(DirAccess.get_files_at(backups).size(), 2, "nur die neuesten zwei bleiben")
	assert_false(FileAccess.file_exists(backups.path_join("world-a.db")))
	var copy := WorldStore.new()
	assert_eq(copy.open(third), OK)
	assert_eq_deep(SimSave.world_to_dict(copy.load_world(data)), SimSave.world_to_dict(world))
	copy.close()
	store.close()


func test_account_db_store_roundtrip_and_legacy_import() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var db_path := DIR.path_join("accounts.db")
	var accounts := Accounts.new(AccountDbStore.new(db_path))
	assert_eq(accounts.login("Anna", "geheim"), "")
	accounts.store.close()
	var reopened := Accounts.new(AccountDbStore.new(db_path))
	assert_eq(reopened.count(), 1)
	assert_ne(reopened.login("anna", "falsch"), "", "falsches Passwort bleibt falsch")
	assert_eq(reopened.login("anna", "geheim"), "")
	assert_eq(reopened.display_name("ANNA"), "Anna")
	reopened.store.close()
	var legacy_path := DIR.path_join("accounts.dat")
	var legacy := Accounts.new(Accounts.AccountFileStore.new(legacy_path))
	assert_eq(legacy.login("Ben", "passwort"), "")
	var fresh := AccountDbStore.new(DIR.path_join("accounts2.db"))
	assert_eq(fresh.import_legacy(legacy_path), 1)
	assert_eq(fresh.import_legacy(legacy_path), 0, "nur in eine leere Datenbank")
	var migrated := Accounts.new(fresh)
	assert_eq(migrated.login("ben", "passwort"), "")
	assert_ne(migrated.login("ben", "anders"), "")
	fresh.close()


func test_runner_persists_world_and_accounts_in_database() -> void:
	var runner := ServerRunner.new()
	runner.data_dir = DIR
	runner.configure(PackedStringArray([str(PORT), "3", "0"]))
	assert_eq(runner.start(), OK)
	assert_true(FileAccess.file_exists(DIR.path_join("world.db")))
	assert_true(FileAccess.file_exists(DIR.path_join("accounts.db")))
	var characters := runner.world.characters.size()
	runner.world.advance(60.0)
	var clock := runner.world.clock_string()
	assert_eq(runner.server.accounts.login("Anna", "geheim"), "")
	runner.stop()
	assert_true(DirAccess.dir_exists_absolute(DIR.path_join("backups")), "erste Sicherung beim Speichern")
	var second := ServerRunner.new()
	second.data_dir = DIR
	second.configure(PackedStringArray([str(PORT + 1), "3", "0"]))
	assert_eq(second.start(), OK)
	assert_eq(second.world.characters.size(), characters, "Füllung wird nicht verdoppelt")
	assert_eq(second.world.clock_string(), clock)
	assert_true(second.server.accounts.has("anna"))
	second.stop()


func test_runner_without_directory_keeps_everything_in_memory() -> void:
	var runner := ServerRunner.new()
	runner.data_dir = ""
	runner.configure(PackedStringArray([str(PORT + 2), "0", "0"]))
	assert_eq(runner.start(), OK)
	assert_null(runner.store)
	assert_not_null(runner.server.accounts, "Konten gibt es auch ohne Datenbank (nur im Speicher)")
	assert_eq(runner.server.accounts.login("Anna", "geheim"), "")
	runner.stop()
	assert_false(DirAccess.dir_exists_absolute(DIR))


## Befund Schritt 55: wer beim Stopp live war, blieb nach dem Neustart vom Spieler gesteuert – ohne Verbindung, ohne
## Regeln, bis er verhungerte. Jetzt loggt er beim Laden mit seinen eigenen Regeln aus.
func test_runner_restart_hands_live_characters_to_their_rules() -> void:
	var runner := ServerRunner.new()
	runner.data_dir = DIR
	runner.configure(PackedStringArray([str(PORT + 3), "0", "0"]))
	assert_eq(runner.start(), OK)
	var world := runner.world
	var anna := world.spawn_player(world.random_player_spawn(), "Anna", "Anna")
	anna.rules = data.roles["guard"]["rules"].duplicate(true)
	anna.role_id = "guard"
	var ben := world.spawn_player(world.random_player_spawn(), "Ben", "Ben")
	ben.rules = []
	var dead := world.spawn_player(world.random_player_spawn(), "Cleo", "Cleo")
	dead.dead = true
	var offline := world.spawn_player(world.random_player_spawn(), "Dora", "Dora")
	world.logout(offline.id, data.roles["hide"]["rules"], "Verstecken")
	var offline_log := SimChronicle.format_all(offline)
	runner.stop()
	var second := ServerRunner.new()
	second.data_dir = DIR
	second.configure(PackedStringArray([str(PORT + 3), "0", "0"]))
	assert_eq(second.start(), OK)
	var a := second.world.get_character(anna.id)
	assert_eq(a.control, SimCharacter.Controller.RULES, "live beim Stopp: jetzt NPC")
	assert_eq(a.rules, data.roles["guard"]["rules"], "mit den eigenen Regeln")
	var lines := SimChronicle.format_all(a)
	assert_true(lines[lines.size() - 1].contains("ausgeloggt als Wache (Server-Neustart)"), "Chronik: %s" % [lines])
	var b := second.world.get_character(ben.id)
	assert_eq(b.control, SimCharacter.Controller.RULES)
	assert_eq(b.rules, data.default_rules, "ohne Regeln: Standardregeln")
	assert_true(SimChronicle.format_all(b)[0].contains("eigene Regeln (Server-Neustart)"))
	assert_true(second.world.get_character(dead.id).dead, "Tote bleiben tot")
	assert_eq(SimChronicle.format_all(second.world.get_character(offline.id)), offline_log, "wer schon offline war, bleibt unberührt")
	assert_true(second.world.get_character(offline.id).rules == data.roles["hide"]["rules"])
	second.stop()


## Füll-NPCs nur für eine neue Welt (vorher füllte jeder Start auf und legte mit jedem Update neue Beute in die Welt), auf
## freiem Boden außerhalb der Zonen, nicht am Spieler-Spawn, ohne Händler.
func test_runner_fills_only_a_new_world_away_from_spawns() -> void:
	var runner := ServerRunner.new()
	runner.data_dir = DIR
	runner.configure(PackedStringArray([str(PORT + 4), "6", "0"]))
	assert_eq(runner.start(), OK)
	assert_true(runner.world_created)
	var fillers := _fillers(runner.world)
	assert_eq(fillers.size(), 6)
	var cells := {}
	for c: SimCharacter in fillers:
		var cell := SimMap.cell_of(c.pos)
		cells[cell] = true
		assert_eq(runner.world.map.tile_id(cell), "floor", "freier Boden")
		assert_eq(runner.world.map.zone(cell), "", "nicht in Markt, Outpost oder Sumpf")
		for spawn: Vector2i in data.player_spawns:
			assert_gte(Vector2(cell).distance_to(Vector2(spawn)), ServerRunner.FILL_SPAWN_DISTANCE, "weg vom Spieler-Spawn")
		for spawn: Vector2i in data.wolf_spawns:
			assert_gt(Vector2(cell).distance_to(Vector2(spawn)), data.balf("wolf.aggro_radius"), "weg vom Wolf-Spawn")
		assert_gt(Vector2(cell).distance_to(Vector2(SimEvents.boss_home_cell(runner.world))), data.balf("events.boss.territory_radius"), "nicht im Leitwolf-Revier")
		assert_ne(c.role_id, "trader", "kein Händler")
		assert_true(data.role_order.has(c.role_id))
		assert_eq(c.control, SimCharacter.Controller.RULES)
		assert_eq(int(c.inventory["berries"]), 5)
	assert_eq(cells.size(), fillers.size(), "jede Zelle nur einmal")
	for a: SimCharacter in fillers:
		for b: SimCharacter in fillers:
			if a != b:
				assert_gte(a.pos.distance_to(b.pos), ServerRunner.FILL_SPACING, "Abstand untereinander")
	fillers[0].dead = true
	runner.stop()
	var second := ServerRunner.new()
	second.data_dir = DIR
	second.configure(PackedStringArray([str(PORT + 5), "20", "0"]))
	assert_eq(second.start(), OK)
	assert_false(second.world_created)
	assert_eq(_fillers(second.world).size(), 5, "geladene Welt: keine Füllung, auch nicht für Tote")
	second.stop()


func _fillers(world: SimWorld) -> Array[SimCharacter]:
	var result: Array[SimCharacter] = []
	for c: SimCharacter in world.characters.values():
		if c.kind == SimCharacter.Kind.PLAYER and not c.dead and c.owner_id.begins_with("füll"):
			result.append(c)
	return result


## Review Schritt 55: der alte Spielstand wurde bei jeder leeren world.db wieder übernommen – wer vor dem Testabend
## world.db beiseitelegte, bekam die Welt von vor Schritt 52 zurück statt einer neuen. Jetzt wird er nach der Übernahme
## umbenannt.
func test_runner_imports_the_legacy_save_only_once() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var legacy := DIR.path_join(ServerRunner.LEGACY_SAVE)
	assert_eq(SimSave.save_to_file(_busy_world(8), legacy), OK)
	var runner := ServerRunner.new()
	runner.data_dir = DIR
	runner.configure(PackedStringArray([str(PORT + 6), "0", "0"]))
	assert_eq(runner.start(), OK)
	assert_false(runner.world_created, "alter Spielstand übernommen")
	runner.stop()
	assert_false(FileAccess.file_exists(legacy), "danach umbenannt")
	assert_true(FileAccess.file_exists(legacy + ServerRunner.LEGACY_DONE_SUFFIX), "aber nicht gelöscht")
	for name: String in DirAccess.get_files_at(DIR):
		if name.begins_with(ServerRunner.WORLD_DB):
			DirAccess.remove_absolute(DIR.path_join(name))  # world.db beiseitelegen (samt -wal/-shm)
	var second := ServerRunner.new()
	second.data_dir = DIR
	second.configure(PackedStringArray([str(PORT + 6), "0", "0"]))
	assert_eq(second.start(), OK)
	assert_true(second.world_created, "ohne world.db: neue Welt")
	second.stop()
