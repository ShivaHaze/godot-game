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
