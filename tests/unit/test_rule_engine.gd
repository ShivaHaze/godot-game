extends GutTest
## Regelmaschine: Priorität, Sonst-Fallback, Parameter, Leine. Ohne Szene, ohne Welt.

var data: SimData


func before_each() -> void:
	data = SimData.load_from_dir("res://data")


func _rule(condition: String, cparams: Dictionary, action: String, aparams: Dictionary = {}) -> Dictionary:
	return data.normalize_rule({"if": {"condition": condition, "params": cparams}, "then": {"action": action, "params": aparams}}, "Test")


func _facts(overrides: Dictionary = {}) -> Dictionary:
	var facts := {
		"always": true,
		"health_percent": 100.0,
		"is_hungry": false,
		"is_under_attack": false,
		"nearest_stranger_distance": SimSensors.FAR,
		"inventory_state": "partial",
	}
	facts.merge(overrides, true)
	return facts


func test_first_matching_rule_wins() -> void:
	var rules := [
		_rule("hungry", {}, "eat"),
		_rule("under_attack", {}, "fight_back"),
		_rule("else", {}, "stay_at"),
	]
	var result := RuleEngine.evaluate(rules, _facts({"is_hungry": true, "is_under_attack": true}), data)
	assert_eq(result["index"], 0, "hungrig steht über angegriffen")
	assert_eq(result["rule"]["then"]["action"], "eat")


func test_priority_follows_list_order() -> void:
	var rules := [
		_rule("under_attack", {}, "fight_back"),
		_rule("hungry", {}, "eat"),
		_rule("else", {}, "stay_at"),
	]
	var result := RuleEngine.evaluate(rules, _facts({"is_hungry": true, "is_under_attack": true}), data)
	assert_eq(result["index"], 0)
	assert_eq(result["rule"]["then"]["action"], "fight_back")


func test_else_fallback_when_nothing_matches() -> void:
	var rules := [
		_rule("hungry", {}, "eat"),
		_rule("under_attack", {}, "fight_back"),
		_rule("else", {}, "hide"),
	]
	var result := RuleEngine.evaluate(rules, _facts(), data)
	assert_eq(result["index"], 2)
	assert_eq(result["rule"]["then"]["action"], "hide")


func test_no_match_without_else() -> void:
	var rules := [_rule("hungry", {}, "eat")]
	var result := RuleEngine.evaluate(rules, _facts(), data)
	assert_eq(result["index"], RuleEngine.NO_MATCH)
	assert_true(result["rule"].is_empty())


func test_health_below_uses_param() -> void:
	var rule := _rule("health_below", {"percent": 30}, "flee_to")
	assert_true(RuleEngine.condition_holds(rule["if"], _facts({"health_percent": 25.0}), data))
	assert_false(RuleEngine.condition_holds(rule["if"], _facts({"health_percent": 30.0}), data), "Grenze ist exklusiv")
	assert_false(RuleEngine.condition_holds(rule["if"], _facts({"health_percent": 80.0}), data))


func test_stranger_near_uses_radius_param() -> void:
	var rule := _rule("stranger_near", {"radius": 5}, "hide")
	assert_true(RuleEngine.condition_holds(rule["if"], _facts({"nearest_stranger_distance": 4.9}), data))
	assert_true(RuleEngine.condition_holds(rule["if"], _facts({"nearest_stranger_distance": 5.0}), data), "Grenze inklusiv")
	assert_false(RuleEngine.condition_holds(rule["if"], _facts({"nearest_stranger_distance": 5.1}), data))
	assert_false(RuleEngine.condition_holds(rule["if"], _facts(), data), "kein Fremder")


func test_inventory_state_choice_param() -> void:
	var full := _rule("inventory_state", {"state": "full"}, "stay_at")
	var empty := _rule("inventory_state", {"state": "empty"}, "gather")
	assert_true(RuleEngine.condition_holds(full["if"], _facts({"inventory_state": "full"}), data))
	assert_false(RuleEngine.condition_holds(full["if"], _facts({"inventory_state": "partial"}), data))
	assert_true(RuleEngine.condition_holds(empty["if"], _facts({"inventory_state": "empty"}), data))
	assert_false(RuleEngine.condition_holds(empty["if"], _facts({"inventory_state": "full"}), data))


func test_unknown_fact_or_condition_never_matches() -> void:
	var rule := _rule("hungry", {}, "eat")
	assert_false(RuleEngine.condition_holds(rule["if"], {"always": true}, data), "Sensorwert fehlt")
	assert_false(RuleEngine.condition_holds({"condition": "moon_phase", "params": {}}, _facts(), data), "unbekannte Bedingung")


func test_compare_operators() -> void:
	assert_true(RuleEngine.compare(3, "<", 4.0))
	assert_true(RuleEngine.compare(4, "<=", 4.0))
	assert_true(RuleEngine.compare(5, ">", 4.0))
	assert_true(RuleEngine.compare(4, ">=", 4.0))
	assert_true(RuleEngine.compare(4, "==", 4.0))
	assert_true(RuleEngine.compare("a", "!=", "b"))
	assert_true(RuleEngine.compare(true, "==", true))
	assert_false(RuleEngine.compare("a", "<", "b"), "Strings sind nicht ordnbar")
	assert_false(RuleEngine.compare(1, "??", 1), "unbekannter Operator")


func test_guard_role_from_data() -> void:
	var rules: Array = data.roles["guard"]["rules"]
	assert_eq(RuleEngine.evaluate(rules, _facts(), data)["rule"]["then"]["action"], "stay_at", "Ruhe: bleibt")
	assert_eq(RuleEngine.evaluate(rules, _facts({"is_under_attack": true}), data)["rule"]["then"]["action"], "fight_back")
	assert_eq(RuleEngine.evaluate(rules, _facts({"is_under_attack": true, "health_percent": 20.0}), data)["rule"]["then"]["action"], "flee_to", "wenig Leben schlägt Kampf")
	assert_eq(RuleEngine.evaluate(rules, _facts({"is_hungry": true}), data)["rule"]["then"]["action"], "eat")


func test_new_condition_needs_no_engine_change() -> void:
	# Eine Bedingung, die es nur in diesem Test gibt: "Leben > X %" nutzt einen vorhandenen Sensorwert.
	data.conditions["health_above"] = {
		"id": "health_above", "label": "Leben > {percent} %", "log": "Leben über {percent} %",
		"params": [{"name": "percent", "type": "int", "default": 50, "min": 1, "max": 99}],
		"check": {"fact": "health_percent", "op": ">", "param": "percent"},
	}
	var rule := _rule("health_above", {"percent": 60}, "gather")
	assert_true(RuleEngine.condition_holds(rule["if"], _facts({"health_percent": 61.0}), data))
	assert_false(RuleEngine.condition_holds(rule["if"], _facts({"health_percent": 60.0}), data))


func test_leash_of_location_rule() -> void:
	var c := SimCharacter.new()
	c.logout_pos = Vector2(3, 4)
	c.markers.append({"id": "m1", "name": "Lager", "pos": Vector2(10, 10)})
	var here := RuleEngine.leash_of(_rule("else", {}, "stay_at", {"place": "here", "radius": 2.5}), c)
	assert_eq(here["center"], Vector2(3, 4))
	assert_eq(here["radius"], 2.5)
	var marker := RuleEngine.leash_of(_rule("else", {}, "gather", {"place": "m1", "resource": "wood"}), c)
	assert_eq(marker["center"], Vector2(10, 10))
	assert_eq(marker["radius"], data.balf("npc.default_leash_radius"), "Voreinstellung aus balance.json")
	assert_true(RuleEngine.leash_of(_rule("else", {}, "eat"), c).is_empty(), "iss hat keine Leine")
