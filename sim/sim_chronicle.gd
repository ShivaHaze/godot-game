class_name SimChronicle
extends RefCounted
## Chronik: protokolliert, was ein Offline-Charakter getan hat. Einträge hängen am Charakter,
## Texte sind Deutsch und kommen aus den Datendateien (log-Vorlagen) plus Details aus der Sim.
## Format: "HH:MM – <Auslöser>, Regel <n>: <Aktion> (<Details>)"


## Hängt einen Eintrag an und meldet ihn als Ereignis des Ticks.
static func add(world: SimWorld, c: SimCharacter, text: String) -> Dictionary:
	var entry := {"time": world.time, "clock": world.clock_string(), "text": text, "pos": c.pos}
	c.chronicle.append(entry)
	world.events.append({"type": "chronicle", "id": c.id, "text": text, "clock": entry["clock"]})
	return entry


static func format_entry(entry: Dictionary) -> String:
	return "%s – %s" % [entry["clock"], entry["text"]]


static func format_all(c: SimCharacter) -> PackedStringArray:
	var lines: PackedStringArray = []
	for entry: Dictionary in c.chronicle:
		lines.append(format_entry(entry))
	return lines


## Nummerierte Zeilen ("3. 08:12 – …"); die Nummern stehen auch an den Orten auf der Karte.
static func format_numbered(c: SimCharacter) -> PackedStringArray:
	var lines: PackedStringArray = []
	for i in c.chronicle.size():
		lines.append("%d. %s" % [i + 1, format_entry(c.chronicle[i])])
	return lines


## Text für eine gefeuerte Regel: "<Auslöser>, Regel <n>: <Aktion>[ (<Details>)]".
static func rule_text(data: SimData, c: SimCharacter, index: int, rule: Dictionary, details: String = "") -> String:
	var condition_def := data.condition_def(String(rule["if"]["condition"]))
	var action_def := data.action_def(String(rule["then"]["action"]))
	var places := c.place_names()
	var trigger := data.format_template(String(condition_def.get("log", "?")), condition_def.get("params", []), rule["if"].get("params", {}), places)
	var action := data.format_template(String(action_def.get("log", "?")), action_def.get("params", []), rule["then"].get("params", {}), places)
	var text := "%s, Regel %d: %s" % [trigger, index + 1, action]
	if not details.is_empty():
		text += " (%s)" % details
	return text


## Protokolliert eine gefeuerte Regel.
static func log_rule(world: SimWorld, c: SimCharacter, index: int, rule: Dictionary, details: String = "") -> Dictionary:
	return add(world, c, rule_text(world.data, c, index, rule, details))
