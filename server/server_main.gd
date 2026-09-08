extends SceneTree
## Headless-Server als Skript-Einstieg: dieselbe Simulation wie im Spiel, autoritativ, 20 Hz, ENet.
## Aufruf: godot --headless --path . -s server/server_main.gd [-- <Port> <NPC-Füllung> <Laufzeit s> <Karte>]
## Karte: Pfad zu einer map.json oder 'gen:120x90:7' (Generator mit Breite×Höhe:Seed); leer = data/map.json.
## Standard: Port 7777, 0 NPCs, unbegrenzt. Die Logik steckt in ServerRunner; das exportierte Programm nutzt
## denselben Runner über `Prototyp-Server --headless --server …` (game/boot.gd).

var runner := ServerRunner.new()
var _last_usec: int = 0


func _init() -> void:
	runner.configure(OS.get_cmdline_user_args())
	if runner.start() != OK:
		quit(1)
		return
	Engine.max_fps = 60
	_last_usec = Time.get_ticks_usec()
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var delta := (now - _last_usec) / 1_000_000.0
	_last_usec = now
	if not runner.update(delta):
		quit()
