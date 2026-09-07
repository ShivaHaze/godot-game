extends GutTest
## Spielstand: Speichern und Laden erhalten den Zustand und den weiteren Verlauf exakt.

const SAVE_PATH: String = "user://test_save.dat"

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")


func after_each() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)


func _busy_world(seed: int) -> SimWorld:
	var world := SimWorld.new(data, seed)
	var id := world.setup_new_game()
	var player := world.get_character(id)
	player.inventory["berries"] = 6
	player.inventory["wood"] = 2
	world.add_marker(id)
	player.pos += Vector2(3, 0)
	world.logout(id, data.roles["gatherer"]["rules"], "Sammler")
	world.advance(300.0)
	return world


func _snapshot(world: SimWorld) -> Dictionary:
	var dict := SimSave.world_to_dict(world)
	dict.erase("projectiles")  # prev_pos von Projektilen ist rein kosmetisch
	return dict


func test_roundtrip_dict_is_identical() -> void:
	var world := _busy_world(4)
	var dict := SimSave.world_to_dict(world)
	var copy := SimSave.world_from_dict(data, dict)
	assert_not_null(copy)
	assert_eq_deep(SimSave.world_to_dict(copy), dict)


func test_loaded_world_continues_identically() -> void:
	var a := _busy_world(9)
	var b := SimSave.world_from_dict(data, SimSave.world_to_dict(a))
	a.advance(1800.0)
	b.advance(1800.0)
	assert_eq_deep(_snapshot(a), _snapshot(b))
	var pa: SimCharacter = a.characters[1]
	var pb: SimCharacter = b.characters[1]
	assert_eq(SimChronicle.format_all(pa), SimChronicle.format_all(pb))
	assert_gt(pa.chronicle.size(), 2)


func test_file_roundtrip_is_exact() -> void:
	var world := _busy_world(2)
	assert_eq(SimSave.save_to_file(world, SAVE_PATH, {"mode": 2, "player_id": 1}), OK)
	var loaded := SimSave.load_from_file(data, SAVE_PATH)
	assert_false(loaded.is_empty(), "geladen")
	var copy: SimWorld = loaded["world"]
	assert_eq(int(loaded["game"]["mode"]), 2)
	assert_eq(int(loaded["game"]["player_id"]), 1)
	assert_eq_deep(_snapshot(copy), _snapshot(world))
	var player: SimCharacter = copy.characters[1]
	assert_true(player.inventory["berries"] is int, "Zahlen bleiben int")
	assert_true(player.rules[0]["if"]["params"]["percent"] is int)
	assert_eq(player.markers[0]["name"], "Marker 1")
	assert_eq(copy.rng.state, world.rng.state, "RNG-Zustand überlebt die Datei exakt")
	world.advance(600.0)
	copy.advance(600.0)
	assert_eq_deep(_snapshot(copy), _snapshot(world))


func test_missing_file_and_wrong_version() -> void:
	assert_true(SimSave.load_from_file(data, "user://gibt_es_nicht.json").is_empty())
	var dict := SimSave.world_to_dict(_busy_world(1))
	dict["version"] = 99
	assert_null(SimSave.world_from_dict(data, dict))


func test_json_snapshot_loads_approximately() -> void:
	var world := _busy_world(6)
	var text := JSON.stringify(SimSave.world_to_dict(world))
	var copy := SimSave.world_from_dict(data, JSON.parse_string(text))
	assert_not_null(copy, "JSON-Snapshot (für Netzwerk) ist ladbar")
	var a: SimCharacter = world.characters[1]
	var b: SimCharacter = copy.characters[1]
	assert_almost_eq(a.pos.x, b.pos.x, 1e-6)
	assert_almost_eq(a.hunger, b.hunger, 1e-6)
	assert_eq(a.chronicle.size(), b.chronicle.size())
	assert_eq(b.inventory["berries"], a.inventory["berries"])
	assert_true(b.inventory["berries"] is int, "JSON-Zahlen werden wieder zu int")
