extends GutTest
## Tests für den Daten-Loader: echte Daten sind gültig, Fehlformate werden gemeldet.


func _load_raw() -> Dictionary:
	var raw := {}
	for key: String in SimData.FILE_NAMES:
		var text := FileAccess.get_file_as_string("res://data".path_join(SimData.FILE_NAMES[key]))
		raw[key] = JSON.parse_string(text)
	return raw


func _assert_errors_contain(data: SimData, fragment: String) -> void:
	var found := false
	for e: String in data.errors:
		if e.contains(fragment):
			found = true
	assert_true(found, "Erwarteter Fehler mit '%s', bekommen: %s" % [fragment, data.errors])


func test_real_data_is_valid() -> void:
	var data := SimData.load_from_dir("res://data")
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_eq(data.resource_order, ["wood", "berries", "meat", "cooked_meat", "stone", "fibers", "cloth", "bandage", "arrow", "copper_ore", "copper", "wire", "iron_ore", "coal", "iron", "sulfur", "powder", "shot", "explosive", "herbs", "antidote", "medicine"] as Array[String])
	assert_eq(data.condition_order.size(), 11, "5 Bedingungen + Sonst + gesperrte 'Fremder im Claim', 'Sensor ausgelöst', 'blutet', 'vergiftet' und 'krank'")
	assert_eq(data.action_order.size(), 11, "6 Start-Aktionen + gesperrte 'greife an', 'verbinde dich', 'stelle her', 'liefere', 'verlange Zoll'")
	assert_eq(data.role_order, ["hide", "guard", "gatherer", "trader"] as Array[String])
	assert_eq(data.else_condition_id, "else")
	assert_eq(data.map_width, 40)
	assert_eq(data.map_height, 30)
	assert_eq(data.map_tile_ids.size(), 40 * 30)
	assert_eq(data.player_spawns.size(), 1)
	assert_eq(data.wolf_spawns.size(), 3)
	assert_eq(data.tile_id_at(0, 0), "obstacle")
	assert_eq(data.tile_id_at(data.player_spawns[0].x, data.player_spawns[0].y), "floor")
	assert_eq(data.tile_id_at(-1, 5), "obstacle", "außerhalb der Karte ist Hindernis")


func test_missing_dir_reports_errors() -> void:
	var data := SimData.load_from_dir("res://gibt_es_nicht")
	assert_false(data.is_valid())
	_assert_errors_contain(data, "Datei fehlt")


func test_balance_accessors() -> void:
	var data := SimData.load_from_dir("res://data")
	assert_eq(data.bali("tick_rate"), 20)
	assert_eq(data.balf("character.move_speed"), 4.0)
	assert_eq(data.balf("npc.default_leash_radius"), 6.0)


func test_missing_balance_key_reported() -> void:
	var raw := _load_raw()
	raw["balance"].erase("wolf")
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "wolf.max_hp")


func test_map_row_length_checked() -> void:
	var raw := _load_raw()
	raw["map"]["rows"][3] = "#..."
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "Zeile 3")


func test_map_unknown_char_reported() -> void:
	var raw := _load_raw()
	var row: String = raw["map"]["rows"][5]
	raw["map"]["rows"][5] = row.substr(0, 10) + "?" + row.substr(11)
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "unbekanntes Zeichen '?'")


func test_unknown_condition_in_role_reported() -> void:
	var raw := _load_raw()
	raw["roles"]["roles"][0]["rules"].insert(0, {"if": {"condition": "moon_phase"}, "then": {"action": "eat"}})
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "unbekannte Bedingung 'moon_phase'")


func test_last_rule_must_be_else() -> void:
	var raw := _load_raw()
	raw["roles"]["roles"][1]["rules"].append({"if": {"condition": "hungry"}, "then": {"action": "eat"}})
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "letzte Regel muss 'Sonst' sein")


func test_else_only_allowed_last() -> void:
	var raw := _load_raw()
	raw["roles"]["roles"][1]["rules"].insert(0, {"if": {"condition": "else"}, "then": {"action": "eat"}})
	var data := SimData.from_dicts(raw)
	_assert_errors_contain(data, "'Sonst' darf nur die letzte Regel sein")


func test_rule_params_get_defaults() -> void:
	var data := SimData.load_from_dir("res://data")
	var rule := data.normalize_rule({"if": {"condition": "health_below"}, "then": {"action": "gather"}}, "Test")
	assert_true(data.is_valid(), "Fehler: %s" % data.errors)
	assert_eq(rule["if"]["params"]["percent"], 50)
	assert_eq(rule["then"]["params"]["place"], "here")
	assert_eq(rule["then"]["params"]["radius"], 6.0)
	assert_eq(rule["then"]["params"]["resource"], "berries")


func test_rule_params_are_clamped_and_typed() -> void:
	var data := SimData.load_from_dir("res://data")
	var rule := data.normalize_rule({"if": {"condition": "health_below", "params": {"percent": 500}}, "then": {"action": "eat"}}, "Test")
	assert_eq(rule["if"]["params"]["percent"], 95, "auf max geklemmt")
	assert_true(rule["if"]["params"]["percent"] is int)


func test_unknown_param_reported() -> void:
	var data := SimData.load_from_dir("res://data")
	data.normalize_rule({"if": {"condition": "hungry", "params": {"foo": 1}}, "then": {"action": "eat"}}, "Test")
	_assert_errors_contain(data, "unbekannter Parameter 'foo'")


func test_format_template_uses_display_values() -> void:
	var data := SimData.load_from_dir("res://data")
	var action: Dictionary = data.action_def("gather")
	var text := data.format_template(action["log"], action["params"], {"resource": "berries", "place": "m1", "radius": 8.0}, {"m1": "Lager"})
	assert_eq(text, "gesammelt: Beeren um Lager")
	var condition: Dictionary = data.condition_def("inventory_state")
	assert_eq(data.format_template(condition["label"], condition["params"], {"state": "empty"}), "Inventar leer")
	assert_eq(data.format_template(action["label"], action["params"], {"place": "here"}), "sammle Beeren um Hier")
