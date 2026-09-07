class_name RuleEngine
extends RefCounted
## Regelmaschine als reine Logik: Sensorwerte (facts) + Regelliste -> erste zutreffende Regel.
## Kennt keine einzelne Bedingung. Jede Bedingung ist laut data/conditions.json ein Vergleich
## "fact op (param | value)". Kein Zustand, keine Nodes, testbar ohne Szene.

const NO_MATCH: int = -1


## Liefert {"index": i, "rule": rule} der ersten zutreffenden Regel, sonst {"index": -1, "rule": {}}.
static func evaluate(rules: Array, facts: Dictionary, data: SimData) -> Dictionary:
	for i in rules.size():
		var rule: Dictionary = rules[i]
		if condition_holds(rule["if"], facts, data):
			return {"index": i, "rule": rule}
	return {"index": NO_MATCH, "rule": {}}


## Prüft einen Regelkopf ({"condition": id, "params": {...}}) gegen die Sensorwerte.
static func condition_holds(if_part: Dictionary, facts: Dictionary, data: SimData) -> bool:
	var def := data.condition_def(String(if_part.get("condition", "")))
	if def.is_empty():
		return false
	var check: Dictionary = def["check"]
	var fact_name := String(check["fact"])
	if not facts.has(fact_name):
		return false
	var params: Dictionary = if_part.get("params", {})
	var expected: Variant
	if check.has("param"):
		if not params.has(check["param"]):
			return false
		expected = params[check["param"]]
	else:
		expected = check["value"]
	return compare(facts[fact_name], String(check["op"]), expected)


static func compare(actual: Variant, op: String, expected: Variant) -> bool:
	var numeric := _is_number(actual) and _is_number(expected)
	match op:
		"<":
			return numeric and float(actual) < float(expected)
		"<=":
			return numeric and float(actual) <= float(expected)
		">":
			return numeric and float(actual) > float(expected)
		">=":
			return numeric and float(actual) >= float(expected)
		"==":
			return float(actual) == float(expected) if numeric else actual == expected
		"!=":
			return float(actual) != float(expected) if numeric else actual != expected
		"has":
			return actual is Array and actual.has(expected)
	return false


## Leine einer Regel: Kreis um den Ort der Aktion. Leer, wenn die Aktion keinen Ort hat.
static func leash_of(rule: Dictionary, c: SimCharacter) -> Dictionary:
	var params: Dictionary = rule.get("then", {}).get("params", {})
	if not params.has("place") or not params.has("radius"):
		return {}
	return {"center": c.place_pos(String(params["place"])), "radius": float(params["radius"])}


static func _is_number(value: Variant) -> bool:
	return value is float or value is int
