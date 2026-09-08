extends CanvasLayer
## Karawanen-Tafel: bei der Rast kauft die Karawane Waren in Kupfer an und verkauft ihre Fracht mit Aufschlag.
## Änderungen laufen über Signale in die Sim (lokal) oder als Nachricht an den Server (online).

signal sell_requested(trader_id: int, resource: String)
signal buy_requested(trader_id: int, resource: String)
signal closed

var data: SimData
var world: SimWorld
var viewer: SimCharacter
var trader: SimCharacter

var _root: PanelContainer
var _title: Label
var _rows: VBoxContainer
var _status: Label


func _ready() -> void:
	layer = 9
	visible = false
	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -400
	_root.offset_right = 400
	_root.offset_top = -220
	_root.offset_bottom = 220
	add_child(_root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_root.add_child(vbox)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)
	var close := Button.new()
	close.text = "Schließen (E)"
	close.pressed.connect(func() -> void: closed.emit())
	vbox.add_child(close)


func open(p_data: SimData, p_world: SimWorld, p_viewer: SimCharacter, p_trader: SimCharacter) -> void:
	data = p_data
	world = p_world
	viewer = p_viewer
	trader = p_trader
	_status.text = ""
	rebuild()
	visible = true


func close() -> void:
	visible = false


func show_status(text: String) -> void:
	_status.text = text


func rebuild() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if trader == null or viewer == null:
		return
	var spec: Dictionary = data.balance["events"]["caravan"]
	var currency := String(spec["currency"])
	var currency_name := String(data.resources[currency]["name"])
	var cargo := SimTrade.caravan_cargo(world, trader)
	_title.text = "Karawane rastet – kauft und verkauft in %s. Kasse der Karawane: %d %s · du hast %d %s." % [
		currency_name, SimTrade.caravan_copper(world, trader), currency_name, int(viewer.inventory.get(currency, 0)), currency_name]
	var prices: Dictionary = spec["prices"]
	for rid: String in data.resource_order:
		if not prices.has(rid):
			continue
		var price: Dictionary = prices[rid]
		var lot := int(price["lot"])
		var pay := int(price["pay"])
		var ask := SimTrade.caravan_ask_price(world, rid)
		var have := int(viewer.inventory.get(rid, 0))
		var stocked := int(cargo.get(rid, 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "%s: dabei %d · Fracht %d" % [data.resources[rid]["name"], have, stocked]
		label.custom_minimum_size = Vector2(260, 0)
		row.add_child(label)
		row.add_child(_button("verkaufe %d für %d %s" % [lot, pay, currency_name], have >= lot, func() -> void: sell_requested.emit(trader.id, rid)))
		row.add_child(_button("kaufe %d für %d %s" % [lot, ask, currency_name], stocked >= lot, func() -> void: buy_requested.emit(trader.id, rid)))
		_rows.add_child(row)


func _button(text: String, enabled: bool, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = not enabled
	button.pressed.connect(callback)
	return button
