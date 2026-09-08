extends CanvasLayer
## Startbildschirm des exportierten Programms: Name, Passwort und Serveradresse eingeben, dann Mehrspieler
## (Verbinden) oder Einzelspieler. Merkt sich Name und Adresse in user://settings.cfg (nie das Passwort).

signal connect_requested(host: String, port: int, player_name: String, password: String)
signal singleplayer_requested
signal quit_requested

const SETTINGS_PATH: String = "user://settings.cfg"
const DEFAULT_ADDRESS: String = "127.0.0.1:7777"
const DEFAULT_PORT: int = 7777

var title_text: String = "Prototyp"
var version_text: String = ""

var _name: LineEdit
var _password: LineEdit
var _address: LineEdit
var _status: Label


func _ready() -> void:
	layer = 20
	_build()
	_load_settings()


## "host:port" oder nur "host" (Standardport). Leer -> {}.
static func parse_address(text: String) -> Dictionary:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return {}
	var parts := trimmed.rsplit(":", true, 1)
	var host := parts[0].strip_edges()
	var port := DEFAULT_PORT
	if parts.size() > 1:
		if not parts[1].strip_edges().is_valid_int():
			return {}
		port = int(parts[1])
	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"host": host, "port": port}


func show_status(text: String) -> void:
	_status.text = text


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.05, 0.05, 0.07)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var root := PanelContainer.new()
	root.anchor_left = 0.5
	root.anchor_right = 0.5
	root.anchor_top = 0.5
	root.anchor_bottom = 0.5
	root.offset_left = -260
	root.offset_right = 260
	root.offset_top = -210
	root.offset_bottom = 210
	add_child(root)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	root.add_child(vbox)
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Dein Charakter handelt weiter, wenn du weg bist." + ((" · " + version_text) if not version_text.is_empty() else "")
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	vbox.add_child(subtitle)
	_name = _field(vbox, "Name", "z. B. Anna", false, 24)
	_password = _field(vbox, "Passwort", "beim ersten Mal frei wählbar", true, 64)
	_address = _field(vbox, "Server", DEFAULT_ADDRESS, false, 80)
	var connect_button := Button.new()
	connect_button.text = "Mehrspieler: Verbinden"
	connect_button.pressed.connect(_on_connect)
	vbox.add_child(connect_button)
	var single := Button.new()
	single.text = "Einzelspieler (lokal, mit Zeitsprung)"
	single.pressed.connect(func() -> void: singleplayer_requested.emit())
	vbox.add_child(single)
	var quit := Button.new()
	quit.text = "Beenden"
	quit.pressed.connect(func() -> void: quit_requested.emit())
	vbox.add_child(quit)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	vbox.add_child(_status)
	var hint := Label.new()
	hint.text = "Server-Adresse als host:port. Der Server muss laufen und Port 7777 (UDP) erreichbar sein."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(hint)


func _field(parent: Control, label_text: String, placeholder: String, secret: bool, max_length: int) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(90, 0)
	row.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.max_length = max_length
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_submitted.connect(func(_text: String) -> void: _on_connect())
	row.add_child(edit)
	parent.add_child(row)
	return edit


func _on_connect() -> void:
	var player_name := _name.text.strip_edges()
	if player_name.length() < 2:
		show_status("Bitte einen Namen mit mindestens 2 Zeichen eingeben.")
		_name.grab_focus()
		return
	var address := parse_address(_address.text if not _address.text.strip_edges().is_empty() else DEFAULT_ADDRESS)
	if address.is_empty():
		show_status("Serveradresse bitte als host:port, zum Beispiel 203.0.113.5:7777.")
		_address.grab_focus()
		return
	_save_settings()
	show_status("Verbinde mit %s:%d …" % [address["host"], address["port"]])
	connect_requested.emit(String(address["host"]), int(address["port"]), player_name, _password.text)


func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	_name.text = String(config.get_value("player", "name", ""))
	_address.text = String(config.get_value("server", "address", ""))


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", _name.text.strip_edges())
	config.set_value("server", "address", _address.text.strip_edges())
	config.save(SETTINGS_PATH)
