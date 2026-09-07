class_name NpcController
extends RefCounted
## Offline-Modus: führt die Regelliste eines Charakters aus. Platzhalter bis Schritt 6 – der NPC steht still.


static func decide(_world: SimWorld, _c: SimCharacter, _dt: float) -> SimIntent:
	return SimIntent.new()
