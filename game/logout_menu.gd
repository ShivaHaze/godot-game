extends CanvasLayer
## Ausloggen-Menü. Oberfläche = Rollen (ein Klick), darunter = Regeln (aufklappbar, editierbar).
## Baut sich vollständig aus den Datendateien auf: Bedingungen, Aktionen und ihre Parameter
## kommen aus conditions.json/actions.json, die Presets aus roles.json. Letzte Zeile ist immer "Sonst".

signal confirmed(rules: Array, role_id: String, role_name: String)
signal cancelled
signal rules_changed(rules: Array)
signal marker_renamed(marker_id: String, new_name: String)
signal marker_removed(marker_id: String)

var data: SimData
var character: SimCharacter
var rules: Array = []          # Arbeitskopie, normalisierte Regeln
var role_id: String = ""

var _root: PanelContainer
var _vbox: VBoxContainer
var _roles_row: HBoxContainer
var _markers_row: HBoxContainer
var _scroll: ScrollContainer
var _role_buttons: Dictionary = {}
var _custom_label: Label
var _tip: Label
var _advanced: CheckButton
var _rules_box: VBoxContainer
var _error_label: Label
var _confirm_button: Button


func _ready() -> void:
	layer = 10
	visible = false
	_build()


func open(p_data: SimData, p_character: SimCharacter, current_rules: Array, current_role: String) -> void:
	data = p_data
	character = p_character
	rules = current_rules.duplicate(true)
	role_id = current_role
	_build_role_buttons()
	_update_role_highlight()
	_rebuild_markers()
	_rebuild_rules()
	_error_label.text = ""
	visible = true
	rules_changed.emit(rules)


## Nach dem Löschen eines Markers (durch main.gd in der Sim): Arbeitskopie der Regeln und Anzeige anpassen.
func on_marker_removed(marker_id: String) -> void:
	for rule: Dictionary in rules:
		var params: Dictionary = rule["then"]["params"]
		if params.get("place", "") == marker_id:
			params["place"] = SimData.PLACE_HERE
	_rebuild_markers()
	_rebuild_rules()
	rules_changed.emit(rules)


func _rebuild_markers() -> void:
	for child: Node in _markers_row.get_children():
		_markers_row.remove_child(child)
		child.queue_free()
	var title := Label.new()
	title.text = "Marker (M setzt live):" if not character.markers.is_empty() else "Marker: noch keiner gesetzt (M im Spiel). Nur Marker und Hier sind als Ort wählbar."
	_markers_row.add_child(title)
	for marker: Dictionary in character.markers:
		var marker_id := String(marker["id"])
		var edit := LineEdit.new()
		edit.text = String(marker["name"])
		edit.custom_minimum_size = Vector2(120, 0)
		edit.text_submitted.connect(func(new_name: String) -> void: _rename(marker_id, new_name))
		edit.focus_exited.connect(func() -> void: _rename(marker_id, edit.text))
		_markers_row.add_child(edit)
		var remove := Button.new()
		remove.text = "löschen"
		remove.pressed.connect(func() -> void: marker_removed.emit(marker_id))
		_markers_row.add_child(remove)


func _rename(marker_id: String, new_name: String) -> void:
	if new_name.strip_edges().is_empty():
		return
	marker_renamed.emit(marker_id, new_name)
	_rebuild_rules()  # Ortsnamen in den Auswahlfeldern aktualisieren


func close() -> void:
	visible = false


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_root = PanelContainer.new()
	_root.anchor_left = 0.5
	_root.anchor_right = 0.5
	_root.anchor_top = 0.5
	_root.anchor_bottom = 0.5
	_root.offset_left = -610
	_root.offset_right = 610
	_root.offset_top = -320
	_root.offset_bottom = 320
	add_child(_root)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	_root.add_child(_vbox)
	var vbox := _vbox

	var title := Label.new()
	title.text = "Ausloggen – was soll dein Charakter tun, während du weg bist?"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_roles_row = HBoxContainer.new()
	_roles_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_roles_row)

	_tip = Label.new()
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.custom_minimum_size = Vector2(1180, 40)
	vbox.add_child(_tip)

	_markers_row = HBoxContainer.new()
	_markers_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_markers_row)

	_advanced = CheckButton.new()
	_advanced.text = "Regeln anzeigen und bearbeiten (Advanced)"
	_advanced.toggled.connect(func(on: bool) -> void: _scroll.visible = on)
	vbox.add_child(_advanced)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(1180, 330)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.visible = false
	vbox.add_child(_scroll)
	_rules_box = VBoxContainer.new()
	_rules_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rules_box.add_theme_constant_override("separation", 4)
	_scroll.add_child(_rules_box)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_error_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 12)
	vbox.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "Abbrechen (Esc)"
	cancel.pressed.connect(func() -> void: cancelled.emit())
	buttons.add_child(cancel)
	_confirm_button = Button.new()
	_confirm_button.text = "Ausloggen"
	_confirm_button.pressed.connect(_on_confirm)
	buttons.add_child(_confirm_button)


func _build_role_buttons() -> void:
	var row := _roles_row
	for child: Node in row.get_children():
		child.queue_free()
	_role_buttons.clear()
	for id: String in data.role_order:
		var button := Button.new()
		button.text = String(data.roles[id]["name"])
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(150, 40)
		button.pressed.connect(_select_role.bind(id))
		row.add_child(button)
		_role_buttons[id] = button
	_custom_label = Label.new()
	_custom_label.text = "(eigene Regeln)"
	row.add_child(_custom_label)


func _select_role(id: String) -> void:
	role_id = id
	rules = data.roles[id]["rules"].duplicate(true)
	_update_role_highlight()
	_rebuild_rules()
	rules_changed.emit(rules)


func _update_role_highlight() -> void:
	for id: String in _role_buttons:
		_role_buttons[id].button_pressed = id == role_id
	if data.roles.has(role_id):
		_tip.text = String(data.roles[role_id]["tip"])
		_custom_label.visible = false
	else:
		_tip.text = "Ohne Rolle gilt das Default-Regelwerk: hungrig → iss · angegriffen → fliehe zu Hier · sonst → bleib bei Hier."
		_custom_label.visible = true


## Jede Änderung an den Regeln macht aus der Rolle "eigene Regeln".
func _mark_custom() -> void:
	role_id = ""
	_update_role_highlight()
	rules_changed.emit(rules)


func _rebuild_rules() -> void:
	for child: Node in _rules_box.get_children():
		_rules_box.remove_child(child)
		child.queue_free()
	for i in rules.size():
		_rules_box.add_child(_make_row(i, rules[i]))
	var add := Button.new()
	add.text = "+ Regel hinzufügen"
	add.pressed.connect(_add_rule)
	_rules_box.add_child(add)


func _add_rule() -> void:
	var rule := data.normalize_rule({"if": {"condition": data.condition_order[0]}, "then": {"action": data.action_order[0]}}, "Editor")
	rules.insert(maxi(0, rules.size() - 1), rule)
	_mark_custom()
	_rebuild_rules()


func _make_row(index: int, rule: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var is_else: bool = rule["if"]["condition"] == data.else_condition_id
	row.add_child(_label("%d." % (index + 1)))
	if is_else:
		row.add_child(_label("Sonst"))
	else:
		row.add_child(_label("Wenn"))
		var condition_ids: Array[String] = []
		for cid: String in data.condition_order:
			if cid != data.else_condition_id:
				condition_ids.append(cid)
		var condition_button := _option_button(condition_ids, func(cid: String) -> String: return _short_label(data.conditions[cid]), String(rule["if"]["condition"]))
		condition_button.item_selected.connect(func(item: int) -> void:
			var cid := condition_ids[item]
			rule["if"] = {"condition": cid, "params": _defaults(data.conditions[cid]["params"])}
			_mark_custom()
			_rebuild_rules())
		row.add_child(condition_button)
		for param_def: Dictionary in data.conditions[rule["if"]["condition"]]["params"]:
			row.add_child(_param_widget(param_def, rule["if"]["params"]))
	row.add_child(_label("dann"))
	var action_ids: Array[String] = []
	action_ids.assign(data.action_order)
	var action_button := _option_button(action_ids, func(aid: String) -> String: return _short_label(data.actions[aid]), String(rule["then"]["action"]))
	action_button.item_selected.connect(func(item: int) -> void:
		var aid := action_ids[item]
		rule["then"] = {"action": aid, "params": _defaults(data.actions[aid]["params"])}
		_mark_custom()
		_rebuild_rules())
	row.add_child(action_button)
	for param_def: Dictionary in data.actions[rule["then"]["action"]]["params"]:
		row.add_child(_param_widget(param_def, rule["then"]["params"]))
	if not is_else:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)
		var up := Button.new()
		up.text = "hoch"
		up.disabled = index == 0
		up.pressed.connect(_move_rule.bind(index, -1))
		row.add_child(up)
		var down := Button.new()
		down.text = "runter"
		down.disabled = index >= rules.size() - 2
		down.pressed.connect(_move_rule.bind(index, 1))
		row.add_child(down)
		var remove := Button.new()
		remove.text = "löschen"
		remove.pressed.connect(_remove_rule.bind(index))
		row.add_child(remove)
	return row


func _move_rule(index: int, delta: int) -> void:
	var target := index + delta
	if target < 0 or target >= rules.size() - 1:
		return
	var rule: Dictionary = rules[index]
	rules.remove_at(index)
	rules.insert(target, rule)
	_mark_custom()
	_rebuild_rules()


func _remove_rule(index: int) -> void:
	rules.remove_at(index)
	_mark_custom()
	_rebuild_rules()


func _defaults(param_defs: Array) -> Dictionary:
	var params := {}
	for param_def: Dictionary in param_defs:
		params[param_def["name"]] = data.param_default(param_def)
	return params


## Label mit "…" statt Parametern, z. B. "Leben < … %".
func _short_label(def: Dictionary) -> String:
	var text := String(def["label"])
	for param_def: Dictionary in def["params"]:
		text = text.replace("{%s}" % param_def["name"], "…")
	return text


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _option_button(ids: Array[String], label_of: Callable, selected_id: String) -> OptionButton:
	var button := OptionButton.new()
	for i in ids.size():
		button.add_item(label_of.call(ids[i]), i)
		if ids[i] == selected_id:
			button.select(i)
	return button


## Eingabefeld für einen Parameter; schreibt direkt in params[name].
func _param_widget(param_def: Dictionary, params: Dictionary) -> Control:
	var name := String(param_def["name"])
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	if param_def.has("label") and String(param_def["type"]) != "int":
		box.add_child(_label(String(param_def["label"]) + ":"))
	match String(param_def["type"]):
		"int", "float":
			var spin := SpinBox.new()
			spin.min_value = float(param_def["min"])
			spin.max_value = float(param_def["max"])
			spin.step = float(param_def.get("step", 1))
			spin.value = float(params.get(name, param_def["default"]))
			if String(param_def["type"]) == "int":
				spin.suffix = String(param_def.get("label", ""))
			spin.value_changed.connect(func(value: float) -> void:
				params[name] = int(value) if String(param_def["type"]) == "int" else value
				_mark_custom())
			box.add_child(spin)
		"radius":
			var spin := SpinBox.new()
			spin.min_value = 0.5
			spin.max_value = 30.0
			spin.step = 0.5
			spin.value = float(params.get(name, data.param_default(param_def)))
			spin.value_changed.connect(func(value: float) -> void:
				params[name] = value
				_mark_custom())
			box.add_child(spin)
		"choice":
			var values: Array[String] = []
			var labels := {}
			for option: Dictionary in param_def["options"]:
				values.append(String(option["value"]))
				labels[option["value"]] = String(option["label"])
			var button := _option_button(values, func(v: String) -> String: return labels[v], String(params.get(name, param_def["default"])))
			button.item_selected.connect(func(item: int) -> void:
				params[name] = values[item]
				_mark_custom())
			box.add_child(button)
		"place":
			var values: Array[String] = [SimData.PLACE_HERE]
			for marker: Dictionary in character.markers:
				values.append(String(marker["id"]))
			var current := String(params.get(name, SimData.PLACE_HERE))
			if not values.has(current):
				current = SimData.PLACE_HERE
				params[name] = current
			var button := _option_button(values, func(v: String) -> String: return character.marker_name(v), current)
			button.item_selected.connect(func(item: int) -> void:
				params[name] = values[item]
				_mark_custom())
			box.add_child(button)
		"resource":
			var values: Array[String] = []
			values.assign(data.resource_order)
			var button := _option_button(values, func(v: String) -> String: return String(data.resources[v]["name"]), String(params.get(name, values[0])))
			button.item_selected.connect(func(item: int) -> void:
				params[name] = values[item]
				_mark_custom())
			box.add_child(button)
	return box


func _on_confirm() -> void:
	var before := data.errors.size()
	var normalized := data.normalize_rule_list(rules, "Regeln")
	var problems := data.errors.slice(before)
	data.errors.resize(before)
	if not problems.is_empty():
		_error_label.text = "\n".join(problems)
		return
	var role_name := String(data.roles[role_id]["name"]) if data.roles.has(role_id) else "eigene Regeln"
	confirmed.emit(normalized, role_id, role_name)
