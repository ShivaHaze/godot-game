extends CanvasLayer
## Kopfanzeige: Uhr, Leben, Hunger, Inventar, Modus, Hinweise, kurze Meldungen,
## Chronik-Tafel (rechts) und Knopfleiste (unten rechts). Liest nur den Sim-Zustand.

var world: SimWorld
var player_id: int = -1
var mode_text: String = "Live"

var _status: Label
var _hint: Label
var _message: Label
var _message_until: float = 0.0
var _chronicle_panel: PanelContainer
var _chronicle_title: Label
var _chronicle_label: Label
var _chronicle_scroll: ScrollContainer
var _buttons: HBoxContainer


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

	_chronicle_panel = PanelContainer.new()
	_chronicle_panel.anchor_left = 1.0
	_chronicle_panel.anchor_right = 1.0
	_chronicle_panel.anchor_bottom = 1.0
	_chronicle_panel.offset_left = -400
	_chronicle_panel.offset_right = -8
	_chronicle_panel.offset_top = 8
	_chronicle_panel.offset_bottom = -52
	_chronicle_panel.visible = false
	add_child(_chronicle_panel)
	var vbox := VBoxContainer.new()
	_chronicle_panel.add_child(vbox)
	_chronicle_title = Label.new()
	_chronicle_title.text = "Chronik"
	_chronicle_title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_chronicle_title)
	_chronicle_scroll = ScrollContainer.new()
	_chronicle_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chronicle_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_chronicle_scroll)
	_chronicle_label = Label.new()
	_chronicle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_chronicle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chronicle_label.custom_minimum_size = Vector2(370, 0)
	_chronicle_label.add_theme_font_size_override("font_size", 13)
	_chronicle_scroll.add_child(_chronicle_label)

	_buttons = HBoxContainer.new()
	_buttons.anchor_left = 1.0
	_buttons.anchor_right = 1.0
	_buttons.anchor_top = 1.0
	_buttons.anchor_bottom = 1.0
	_buttons.offset_left = -700
	_buttons.offset_right = -8
	_buttons.offset_top = -44
	_buttons.offset_bottom = -8
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	add_child(_buttons)


func set_hint(text: String) -> void:
	_hint.text = text


func show_message(text: String, seconds: float = 2.5) -> void:
	_message.text = text
	_message_until = Time.get_ticks_msec() / 1000.0 + seconds


func add_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	_buttons.add_child(button)
	return button


func clear_buttons() -> void:
	for child: Node in _buttons.get_children():
		child.queue_free()


func show_chronicle(visible: bool, title: String = "Chronik") -> void:
	_chronicle_panel.visible = visible
	_chronicle_title.text = title


func set_chronicle(lines: PackedStringArray) -> void:
	var text := "\n".join(lines) if not lines.is_empty() else "(noch nichts passiert)"
	if _chronicle_label.text == text:
		return
	_chronicle_label.text = text
	_scroll_chronicle_to_end.call_deferred()


func _scroll_chronicle_to_end() -> void:
	_chronicle_scroll.scroll_vertical = int(_chronicle_scroll.get_v_scroll_bar().max_value)


func refresh() -> void:
	if world == null:
		return
	if Time.get_ticks_msec() / 1000.0 > _message_until:
		_message.text = ""
	var c := world.get_character(player_id)
	if c == null:
		_status.text = "Modus: %s\nUhr %s" % [mode_text, world.clock_string()]
		return
	var inventory_parts: PackedStringArray = []
	for rid: String in world.data.resource_order:
		inventory_parts.append("%s %d" % [world.data.resources[rid]["name"], int(c.inventory.get(rid, 0))])
	var hunger_text := "%d" % int(c.hunger)
	if c.is_weakened():
		hunger_text += " (geschwächt)"
	elif c.hunger < world.data.balf("hunger.hungry_threshold"):
		hunger_text += " (hungrig)"
	var state := ""
	if c.dead:
		state = "\nTOT"
	elif c.hidden:
		state = "\nversteckt"
	_status.text = "Modus: %s\nUhr %s\nLeben %d/%d\nHunger %s\n%s (%d/%d)%s" % [
		mode_text,
		world.clock_string(),
		int(ceilf(c.hp)), int(c.max_hp),
		hunger_text,
		" · ".join(inventory_parts), c.inventory_count(), world.data.bali("inventory.capacity"),
		state,
	]
