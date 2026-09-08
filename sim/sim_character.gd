class_name SimCharacter
extends RefCounted
## Ein Körper in der Welt: Spielercharakter (live oder als Offline-NPC) oder Wolf.
## Reine Daten plus kleine Abfragen. Verändert wird er nur von SimWorld.

enum Kind { PLAYER, WOLF }
enum Controller { PLAYER, RULES, WOLF_AI, NONE }

var id: int = 0
var name: String = ""
var kind: Kind = Kind.PLAYER
var control: Controller = Controller.NONE
var owner_id: String = ""            # Gleicher Besitzer = kein Fremder. Tiere: "wild"
var boss: bool = false               # Ereignis-Tier (Leitwolf): stärker, flieht nie, Beute in der Leiche

var pos: Vector2 = Vector2.ZERO
var prev_pos: Vector2 = Vector2.ZERO # Position vor dem letzten Tick (für weiche Darstellung)
var facing: Vector2 = Vector2.RIGHT
var move_speed: float = 4.0
var collision_radius: float = 0.35

var hp: float = 30.0
var max_hp: float = 30.0
var armor: float = 0.0
var armor_slow: float = 0.0          # Anteil, um den die getragene Rüstung verlangsamt (0 = keine)
var dead: bool = false
var death_time: float = -1e9
var melee_damage: float = 0.0        # 0 = kein Nahkampf (Spielercharaktere schießen nur)
var melee_range: float = 0.9
var melee_cooldown: float = 1.0
var melee_effect: String = ""       # Zustandseffekt der Nahkampfwaffe (z. B. bleeding)
var effects: Dictionary = {}         # Zustandseffekt -> Sim-Zeit, bis zu der er wirkt

var hunger: float = 100.0
var inventory: Dictionary = {}       # Rohstoff-Kennung -> Anzahl
var items: Array[String] = []        # Besessene Ausrüstung (Kennungen aus items.json)
var active_weapon: String = ""       # Aktive Waffe (Kennung) oder leer
var worn_armor: String = ""          # Angelegte Rüstung (Kennung) oder leer; wird explizit an- und abgelegt, nie automatisch
var durability: Dictionary = {}      # Gegenstand -> {"left": Rest, "max": aktuelles Maximum}; siehe balance.json wear

var fire_cooldown: float = 0.0
var last_damage_time: float = -1e9   # Sim-Zeit des letzten erlittenen Treffers
var last_attacker_id: int = -1

var gather_progress: float = 0.0
var gather_target: Vector2i = Vector2i(-1, -1)
var heal_progress: float = 0.0       # Kanalisierung eines Verbands in Sekunden

var hidden: bool = false
var hide_progress: float = 0.0       # Sekunden ohne Schaden seit Beginn des Versteckens
var revealed_until: float = -1e9     # Bis zu dieser Sim-Zeit kann man sich nicht (wieder) verstecken

# Regelwerk und Orte (nur für Spielercharaktere relevant)
var rules: Array = []                # normalisierte Regeln, siehe data/README.md
var markers: Array[Dictionary] = []  # {id, name, pos}
var extra_places: Dictionary = {}    # Orte aus eigenen Bauteilen (Sensoren): "b<id>" -> {name, pos}; die Welt pflegt sie
var marker_counter: int = 0          # Zähler für Marker-Kennungen (werden nicht wiederverwendet)
var logout_pos: Vector2 = Vector2.ZERO  # "Hier"
var logout_time: float = -1e9        # Sim-Zeit des Ausloggens (Logout-Übergang)
var transition_logged: bool = false  # Ende des Übergangs schon in der Chronik vermerkt
var chronicle: Array[Dictionary] = []   # {time, text}
var active_rule_index: int = -1
var skipped_rules: Dictionary = {}   # Regelindex -> {reason, time}: zuletzt vermerkte Übersprünge (gegen Chronik-Spam)
var last_logged_rule_index: int = -1 # zuletzt protokollierte Regel; dieselbe Regel nach einer Pause wird nicht erneut protokolliert
var action_state: Dictionary = {}    # Zwischenzustand der aktiven Aktion (z. B. Sammelziel)
var role_id: String = ""             # Zuletzt gewählte Rolle (nur Anzeige)
var decision_timer: float = 0.0
var leash_center: Vector2 = Vector2.ZERO
var leash_radius: float = 0.0

# Simulationsstufen (Server): fern von Online-Spielern nur alle coarse_tick_dt Sekunden rechnen
var lod_accumulator: float = 0.0
var lod_fine_steps: int = 0          # Zähler für Benchmarks/Tests
var lod_coarse_steps: int = 0

# Wegsuche (Controller)
var path: Array[Vector2i] = []
var path_goal: Vector2i = Vector2i(-1, -1)
var path_age: float = 0.0

# Wolf-KI
var ai_state: String = "wander"
var ai_timer: float = 0.0
var ai_target_pos: Vector2 = Vector2.ZERO
var home_pos: Vector2 = Vector2.ZERO
var bite_cooldown: float = 0.0


func inventory_count() -> int:
	var total := 0
	for amount: int in inventory.values():
		total += amount
	return total


func health_percent() -> float:
	return 100.0 * hp / max_hp if max_hp > 0.0 else 0.0


func is_weakened() -> bool:
	return kind == Kind.PLAYER and hunger <= 0.0


func is_alive() -> bool:
	return not dead


func render_pos(alpha: float) -> Vector2:
	return prev_pos.lerp(pos, clampf(alpha, 0.0, 1.0))


func marker_name(place_id: String) -> String:
	if place_id == SimData.PLACE_HERE:
		return "Hier"
	for marker: Dictionary in markers:
		if marker["id"] == place_id:
			return String(marker["name"])
	if extra_places.has(place_id):
		return String(extra_places[place_id]["name"])
	if SimData.SYMBOLIC_PLACES.has(place_id):
		return String(SimData.SYMBOLIC_PLACES[place_id]["name"])
	return place_id


## Position eines Orts ("here" oder Marker-Kennung). Unbekannt -> logout_pos.
func place_pos(place_id: String) -> Vector2:
	if place_id == SimData.PLACE_HERE:
		return logout_pos
	for marker: Dictionary in markers:
		if marker["id"] == place_id:
			return marker["pos"]
	if extra_places.has(place_id):
		return extra_places[place_id]["pos"]
	return logout_pos


func place_names() -> Dictionary:
	var names := {}
	for marker: Dictionary in markers:
		names[marker["id"]] = marker["name"]
	for id: String in extra_places:
		names[id] = extra_places[id]["name"]
	return names
