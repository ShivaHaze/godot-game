extends CanvasLayer
## Kopfanzeige: Uhr, Leben, Hunger, Inventar, Modus, Hinweise, kurze Meldungen. Liest nur den Sim-Zustand.

var world: SimWorld
var player_id: int = -1
var mode_text: String = "Live"

var _status: Label
var _hint: Label
var _message: Label
var _message_until: float = 0.0


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	add_child(panel)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	panel.add_child(_status)

	_hint = Label.new()
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.anchor_right = 1.0
	_hint.offset_top = -30
	_hint.offset_left = 8
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.text = "WASD bewegen · Maus zielen · Linksklick schießen · E halten: sammeln · F essen · M Marker · Esc Ausloggen"
	add_child(_hint)

	_message = Label.new()
	_message.anchor_left = 0.5
	_message.anchor_right = 0.5
	_message.offset_left = -300
	_message.offset_right = 300
	_message.offset_top = 12
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.add_theme_font_size_override("font_size", 16)
	_message.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	add_child(_message)


func set_hint(text: String) -> void:
	_hint.text = text


func show_message(text: String, seconds: float = 2.5) -> void:
	_message.text = text
	_message_until = Time.get_ticks_msec() / 1000.0 + seconds


func refresh() -> void:
	if world == null:
		return
	if Time.get_ticks_msec() / 1000.0 > _message_until:
		_message.text = ""
	var c := world.get_character(player_id)
	if c == null:
		_status.text = "Uhr %s" % world.clock_string()
		return
	var inventory_parts: PackedStringArray = []
	for rid: String in world.data.resource_order:
		inventory_parts.append("%s %d" % [world.data.resources[rid]["name"], int(c.inventory.get(rid, 0))])
	var hunger_text := "%d" % int(c.hunger)
	if c.is_weakened():
		hunger_text += " (geschwächt)"
	elif c.hunger < world.data.balf("hunger.hungry_threshold"):
		hunger_text += " (hungrig)"
	_status.text = "Modus: %s\nUhr %s\nLeben %d/%d\nHunger %s\n%s (%d/%d)" % [
		mode_text,
		world.clock_string(),
		int(ceilf(c.hp)), int(c.max_hp),
		hunger_text,
		" · ".join(inventory_parts), c.inventory_count(), world.data.bali("inventory.capacity"),
	]
