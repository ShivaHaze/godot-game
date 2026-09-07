class_name SimIntent
extends RefCounted
## Steuerabsicht für einen Tick. Wird vom Spieler (Eingabe) oder von einem Controller
## (Regelmaschine, Wolf-KI) erzeugt. Die Sim wendet sie für alle Charaktere gleich an.

var move: Vector2 = Vector2.ZERO      # Bewegungsrichtung, Länge ≤ 1
var aim: Vector2 = Vector2.ZERO       # Zielrichtung in Weltkoordinaten; ZERO = Blick folgt der Bewegung
var shoot: bool = false               # Projektil abfeuern (wenn Cooldown und Limit es erlauben)
var interact: bool = false            # An nächster Quelle sammeln (gedrückt halten)
var eat: bool = false                 # Ein essbares Stück aus dem Inventar essen
var hide: bool = false                # Verstecken beginnen / beibehalten
var melee: bool = false               # Nahkampfangriff auf den nächsten Feind in melee_range (Wolf: Biss)
var gather_cell: Vector2i = Vector2i(-1, -1)  # Gezielte Quelle beim Sammeln; (-1, -1) = nächste in Reichweite
var heal: bool = false                # Verband anlegen (Kanalisierung; Angriff bricht ab)
