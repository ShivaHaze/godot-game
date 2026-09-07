class_name SimProjectile
extends RefCounted
## Ein langsames, sichtbares Projektil. Bewegung und Treffer in SimWorld.

var owner_id: int = -1          # Charakter-Kennung des Schützen
var pos: Vector2 = Vector2.ZERO
var prev_pos: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var damage: float = 0.0
var lifetime: float = 0.0       # Verbleibende Sekunden
