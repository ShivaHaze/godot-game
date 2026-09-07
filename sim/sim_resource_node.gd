class_name SimResourceNode
extends RefCounted
## Eine Rohstoffquelle auf einer Kachel (Holzquelle, Beerenbusch). Vorrat wächst nach.

var cell: Vector2i = Vector2i.ZERO
var resource: String = ""
var amount: int = 0
var max_amount: int = 0
var regrow_timer: float = 0.0


func center() -> Vector2:
	return Vector2(cell) + Vector2(0.5, 0.5)
