class_name SimClaim
extends RefCounted
## Ein Claim: Anker, zusammenhängende Kacheln, Holzvorrat für den Unterhalt.

var id: int = 0
var owner_id: String = ""
var anchor_building_id: int = -1     # -1 = Anker zerstört, Schonfrist läuft
var anchor_tile: Vector2i = Vector2i.ZERO
var tiles: Dictionary = {}           # Vector2i -> true
var stock: float = 0.0               # Holz am Anker
var starving_since: float = -1.0     # Sim-Zeit, seit der der Vorrat leer ist (-1 = versorgt)
var grace_until: float = -1.0        # Ohne Anker: bis dahin kann neu verankert werden
var hours_left_hint: float = -1.0    # Nur Client-Spiegel: Reichweite des Vorrats laut Server
var toll: Dictionary = {}            # Zoll-Gedächtnis je Fremdem (owner_id): {debt, paid_until, last_seen, demanded, attacking}
