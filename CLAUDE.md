# CLAUDE.md – Phase 0: Rechteck-Prototyp

## Projektziel
Ein Single-Player-Prototyp in Godot 4.7.x (GDScript), der genau eine Frage beantwortet: Fühlt sich der Kern-Twist gut an?
Der Twist: Beim "Ausloggen" wird der Spielercharakter zum NPC, der nach vom Spieler festgelegten Wenn-Dann-Regeln weiterhandelt; der Spieler springt 8 Stunden in die Zukunft, findet seinen Charakter vor und liest in der Chronik, was passiert ist.

**Design-Dokument: `docs/design-doc.md`.** Legende dort: **[E]** entschieden (wird nicht diskutiert) · **[T]** Tendenz · **[O]** offen. Abschnitt 8 beschreibt Phase 0 und die beim Bau getroffenen Entscheidungen.
Designfragen, die das Dokument nicht beantwortet: **nicht raten, fragen.** Eigene Entscheidungen, die das Design berühren, dort als [T]/[O] eintragen und Bescheid sagen.

## Stand (2026-09-07)
Schritte 1–8 (Phase 0) plus 9–35 sind gebaut und committet: Gerüst, Daten, Sim-Kern, Regelmaschine + Chronik, Kampf + Wolf, NPC-Modus, Ausloggen-Menü, Zeitsprung + Gegen-sich-selbst, Spielstand, Logout-Übergang, Chronik-Spur, Marker verwalten, Werkbank/Ausrüstung, Balancing-Bericht, Simulationsstufen + Nachbarschaftsraster, Netzwerk-Spike (headless ENet-Server, Bot-Clients, Netzwerk-Client im Spiel), Freischalten von Regel-Bausteinen ('greife an'), Kartengenerator + Karte im Beitritt, Bauen (Holzwand, Holztür auf Halbkachelraster), Claims (Anker, Kacheln, Unterhalt, Schrumpfen, Rechte), Handelstisch (Lager, Angebote, Kauf, Beute), Stein/Fasern/Verband/Steinbeil mit Heilung als Kanalisierung, Sensoren (Bedingung über Distanz, Ort in Regeln) und Fallen (für Fremde unsichtbar), Lieferung per NPC (Anker/Handelstisch als Orte), Chat (nah/global über den Server) und Schilder (Text, den jeder in der Nähe liest), Spawn-Anker als Claim-Upgrade (neue Charaktere erscheinen daneben), Zustandseffekt Blutung (Steinbeil ↔ Verband, Bedingung 'blutet'), Verschleiß und Reparatur (Haltbarkeit je Gegenstand, Werkbank repariert mit sinkendem Maximum), neutraler Markt (kampffreie Kartenzone M mit Markt-Depot D: Gebühr, Ort für alle, NPC-Lieferung), Stoff-Kette (Fasern → Stoff → Verband/Stoffrüstung) mit NPC-Aktion 'stelle her', Bogen mit Pfeilen als Munition (Senke; NPC greift ohne Pfeile zur nächsten Waffe), Kupferkette (Kupferader am Kartenrand → Kupfer mit Holz als Brennstoff → Draht für Sensoren, Kupferspeer), Namen nur in unmittelbarer Nähe (Anzeige 'Fremder', Chronik 'Unbekannter mit <Waffe>', Stammdaten im Netz ohne Name bis zur Nähe), Eisenkette (Eisenader/Kohleflöz in der Mitte, offline nur mit Mine daneben, Eisen braucht Kohle, Eisenaxt bricht Steinwände, Eisenrüstung macht langsam), Schwefelkette und Turrets (Schwefel nur live im Zentrum → Pulver → Kugeln; Turret schießt auf Fremde mit Sichtlinie, Besitzer/NPC laden Munition; Raidwaren nicht ins Markt-Depot), Sprengsatz als Raidwerkzeug (auf fremdem Claim legbar, Lunte, trifft jede Bauteil-Stufe) und Verrotten von Leichen nach 24 h, Räuber-Outpost als zweite Kartenzone (kein Kampfverbot, Depot mit 5 % Gebühr, Raidwaren erlaubt; Zonen datengetrieben in balance.json), Sumpf mit Vergiftung und Kräutern (Gegenmittel, Medizin, Bedingung 'vergiftet', H wählt das passende Heilmittel), Lagerfeuer und Fleisch (Wölfe geben Fleisch, gebraten am Feuer doppelt so nahrhaft wie Beeren; Essen nimmt das beste Stück). 215 Tests laufen headless grün. Phase 1 läuft in der Reihenfolge Bauen → Claims → Handelstisch → Rohstoffe/Ketten → Sensoren/Turrets (Design-Dokument Abschnitt 8).

## Scope Phase 0 (nichts darüber hinaus ohne Rückfrage)
- Karte aus Datendatei (Kacheln: Boden, Hindernis, Holzquelle, Beerenbusch, Steinbruch, Faserpflanze, Kupferader, Eisenader, Kohleflöz, Schwefelgrube, Sumpf, Kräuter, Marktplatz, Räuber-Outpost). Rechtecke, keine Grafik.
- Spieler: WASD, Twin-Stick-Schuss (Maus), 1–3 langsame sichtbare Projektile, Richtungstreffer (hinten/seitlich = mehr Schaden), HP, flacher Rüstungsabzug als Parameter.
- Inventar: Holz, Beeren. Sammeln per Interaktion. Leichen sind plünderbar (Rohstoffe und Ausrüstung).
- Ausrüstung aus `data/items.json`: Schleuder (Start), Bogen (braucht Pfeile), Keule, Steinbeil, Stoffrüstung und Holzpanzer an der Werkbank (C); Q wechselt die Waffe. Verschleiß und Reparatur siehe balance.json `wear`.
- Hunger als Unterhalt: sinkt langsam, bei 0 geschwächt (halbe Geschwindigkeit), nicht tot.
- Wolf-KI: nähert sich, beißt, flieht bei niedrigem HP, kommt nach.
- Ausloggen-Menü: 4 Rollen-Presets (Verstecken, Wache, Sammler, Händler-Platzhalter), jede Rolle = vorausgefüllte, aufklappbare, editierbare Regelliste.
- Regelsystem: Prioritätenliste, erste zutreffende (und ausführbare) Regel gewinnt, letzte Zeile immer "Sonst". Startvokabular exakt wie im Design: Bedingungen *Leben < X %, hungrig, wird angegriffen, Fremder in Nähe [Radius], Inventar voll/leer*; Aktionen *fliehe zu [Ort], bleib bei [Ort], sammle [Rohstoff] um [Ort], iss, kämpfe zurück, verstecken*. Kein "greife an".
- Marker + Leine: Marker live per Taste (M), im Menü umbenennen/löschen; nur Marker plus "Hier" sind als [Ort] wählbar; jede Ortsregel hat einen Radius, sichtbar als Kreis (auch als Vorschau im Menü); der NPC verlässt die Leine nie.
- NPC-Modus: gleiches Kampfsystem wie der Spieler, aber schlechter (zielt auf aktuelle statt zukünftige Position, dreht sich zur Bedrohung, handelt vorsichtig).
- Chronik: jede gefeuerte Regel mit Zeitstempel und Ort, beim Zurückkommen lesbar, als nummerierte Spur auf der Karte.
- Logout-Übergang (45 s, bei Kampf länger): sichtbar, verwundbar, kein Verstecken.
- Spielstand `user://save.dat` automatisch; `main.save_path = ""` schaltet ihn für Tests und Werkzeuge ab.
- Zeitsprung "8 Stunden überspringen" = Sim ticken ohne zu zeichnen (grob ohne Gefahr, fein bei Kampf).
- Gegen-sich-selbst-Modus: frischer Charakter (Besitzer p2) gegen den eigenen NPC von "gestern".

**Nicht im Scope:** Netzwerk (kommt als Spike), Bauen, Claims, Gilden, Handel, weitere Rohstoffe, Zustandseffekte, Grafik, Sound, Setting. Keine Assets, keine Addons außer GUT. Alles sind ColorRects, Linien und Labels.

## Architektur-Vorgaben (nicht verhandelbar)
1. **Simulation getrennt von Darstellung.** Alles, was den Weltzustand verändert (Bewegung, Kampf, Hunger, Regeln, Sammeln), lebt in `sim/` und läuft mit festem Tick (20 Hz). `sim/` verwendet keine Nodes, keine Szenen, keine Autoloads, kein `get_tree()`, kein `Input` – nur `RefCounted`-Klassen und reine Daten. `game/` liest den Sim-Zustand nur aus, zeichnet und schreibt ausschließlich `SimIntent`s hinein. Grund: Die Sim läuft später unverändert auf einem Godot-headless-Server. Zeitsprung = `SimWorld.advance()`.
2. **Datengetrieben.** Regel-Bausteine (Bedingungen, Aktionen), Rollen-Presets, Rohstoffe, Karte und Balancing liegen als JSON unter `data/`. Eine neue Bedingung ist ein Eintrag in `conditions.json` (Sensorwert + Vergleich); die Regelmaschine bleibt unverändert (per Test belegt). Ein neuer Sensorwert ist eine Zeile in `sim/sim_sensors.gd`.
3. **Regelmaschine als reine Logik.** `RuleEngine.evaluate(rules, facts, data)`: Eingabe Sensorwerte + Regelliste, Ausgabe erste zutreffende Regel. Testbar ohne Szene.
4. **Tests für die Sim** laufen headless (GUT). Abgedeckt: Regelmaschine (Priorität, Sonst-Fallback, Leine), Hunger-Tick, Richtungstreffer, Karte/Kollision/Wegsuche, Kampf, Wolf, NPC-Controller, Zeitsprung, Determinismus, Menü und Hauptszene.
5. **Balancing sichtbar.** Alle Tuning-Werte in `data/balance.json` (mit `_`-Erklärungen), ohne Code-Kenntnis editierbar. Pflichtschlüssel werden beim Laden geprüft (`SimData.REQUIRED_BALANCE`).
6. **Determinismus.** Die Sim nutzt einen eigenen, geseedeten `RandomNumberGenerator` (kein globales `randi()`); gleicher Seed = gleicher Zeitsprung (per Test belegt).
7. **Simulationsstufen.** Charaktere ohne Online-Spieler (oder Zuschauer, `SimWorld.observer_ids`) in `offline.lod_radius` rechnen einmal pro `coarse_tick_dt` mit großem Schritt. `world.lod_enabled = false` erzwingt Feinsimulation (Tests). Umkreis-Abfragen laufen über `SimSpatial`, gültig nach jedem `step()`; wer Positionen von Hand setzt und dann abfragt, ruft `world.spatial.rebuild(world.characters)`.

**Warum JSON statt Godot-Resources:** ohne Editor les- und editierbar, diffbar in Git, keine `class_name`-Registrierung nötig, identisches Laden auf Client und headless-Server. Typprüfung übernimmt `sim/sim_data.gd`.

## Ordnerstruktur
```
project.godot        Godot-Projekt (Input-Map: move_*, shoot, interact, eat, place_marker, logout_menu, respawn)
CLAUDE.md            diese Datei
docs/design-doc.md   Design-Dokument (Wahrheit für alle Designfragen)
data/                JSON: balance, resources, tiles, map, conditions, actions, roles, items, buildings (+ README.md)
sim/                 Simulation ohne Nodes:
  sim_data.gd          Loader + Validierung + Regel-Normalisierung + Textvorlagen
  sim_world.gd         Weltzustand, Tick/step(dt), Intents, Kampf (Waffen), Hunger, Sammeln, Plündern, Verstecken,
                       Wölfe, Marker, Werkbank (craft), logout()/login(), Übergang, advance()/advance_until(), is_hot()
  sim_save.gd          Weltzustand <-> Dictionary (JSON-fähig) und exakte Spielstand-Datei
  sim_map.gd           Karte, Kollision (Kreis vs. Kacheln, Gleiten, Substeps), Quellen, A*
  sim_character.gd     Charakterdaten (Spieler live / NPC / Wolf)
  sim_intent.gd        Steuerabsicht pro Tick (move, aim, shoot, interact, eat, hide, melee)
  sim_projectile.gd, sim_resource_node.gd, sim_building.gd, sim_claim.gd   Daten
  sim_claims.gd        Land: Anker, Kacheln, Unterhalt, Schrumpfen, Schonfrist, Rechte (world.claims)
  sim_combat.gd        Richtungstreffer + Rüstung (reine Logik)
  sim_sensors.gd       Sensorwerte ("facts") für die Regelmaschine
  rule_engine.gd       Regelmaschine (reine Logik)
  sim_chronicle.gd     Chronik-Einträge und -Texte
  npc_controller.gd    Offline-Modus: Regelliste ausführen, Leine, Aktionen
  wolf_ai.gd           Wolf-Verhalten
  sim_nav.gd           Wegfolge (A*, Sichtlinie, kein Überschießen bei groben Ticks)
  sim_spatial.gd       Nachbarschaftsraster (pro Tick neu), Basis aller Umkreis-Abfragen
  map_gen.gd           Seedbarer Kartengenerator (zusammenhängend, Spawns am Rand, Wölfe innen)
  net_protocol.gd      Nachrichten: Absichten, Snapshots (Sichtbereich, kompakt), eigene Details, Spiegelwelt füllen
server/              Headless-Server: net_server.gd (ENet, Absichten rein, Snapshots raus, Trennen = NPC), server_main.gd (Startskript)
game/                Darstellung und Eingabe (liest sim/, schreibt nur Intents):
  main.gd/.tscn        Modi Live / Menü / Offline / Zeitsprung / Versus, Tick-Akkumulator, Kamera
  world_view.gd        Zeichnet Karte, Quellen, Charaktere, Projektile, Marker, Leinen (interpoliert)
  hud.gd               Status, Hinweise, Meldungen, Chronik-Tafel, Knopfleiste
  logout_menu.gd       Rollen + Regel-Editor + Marker verwalten, aus den Daten gebaut
  craft_panel.gd       Werkbank aus items.json
  trade_panel.gd       Handelstisch-Tafel (Besitzer: Lager und Angebote; Fremde: kaufen)
  net_client.gd        Netzwerk-Client: Spiegelwelt aus Snapshots, sendet Absichten und Menü-Aktionen
tests/unit/          GUT-Tests (test_*.gd)
tools/               run_tests.ps1 / run_tests.sh (headless), smoke_run.gd (Rauchtest mit Fenster), screenshot_run.gd (Bildschirmfotos),
                     balance_report.gd (Rollen × Seeds × 8 h headless, druckt Überleben/Vorräte),
                     server_bench.gd (N NPCs + Spieler headless bei 20 Hz, Tickzeit und Simulationsstufen),
                     bot_clients.gd (N ENet-Clients gegen einen Server), net_smoke.gd (Client mit Fenster gegen einen Server),
                     map_gen.gd (Karte als JSON schreiben)
addons/gut/          Test-Framework GUT 9.6.1 (einziges Addon)
```

## Tests starten
```
tools\run_tests.ps1      # PowerShell
tools/run_tests.sh       # Git Bash
```
Direkt (aus dem Projektordner):
```
godot --headless --path . --import
godot --headless --path . -s addons/gut/gut_cmdln.gd
```
`--import` baut den Cache in `.godot/` auf; ohne ihn sind `class_name`-Klassen headless nicht auflösbar. Exit-Code 0 = alle Tests grün. GUT liest `res://.gutconfig.json` automatisch (kein `-gconfig`-Argument: der `godot.cmd`-Wrapper zerlegt Argumente mit `=`).
Zeichen- und UI-Code läuft headless nicht; dafür: `godot --path . -s tools/smoke_run.gd` (öffnet kurz ein Fenster, meldet `SMOKE OK`).
Bildschirmfotos aller Ansichten: `godot --path . -s tools/screenshot_run.gd -- <Ordner>`.
Balancing-Bericht: `godot --headless --path . -s tools/balance_report.gd -- 5 8` (Seeds, Stunden).
Server-Benchmark: `godot --headless --path . -s tools/server_bench.gd -- 300 5 30` (NPCs, Spieler, Sekunden).

## Netzwerk (Spike)
```
godot --headless --path . -s server/server_main.gd -- 7777 200 0      # Server: Port, NPC-Füllung, Laufzeit (0 = endlos)
godot --headless --path . -s server/server_main.gd -- 7777 300 0 gen:120x90:7   # ... mit generierter großer Karte
godot --headless --path . -s tools/map_gen.gd -- 120 90 7 data/maps/gross.json  # Karte als Datei
godot --path . -- --connect 127.0.0.1:7777 --name Anna                 # Spiel als Client
godot --headless --path . -s tools/bot_clients.gd -- 50 127.0.0.1 7777 60   # 50 Bots für 60 s
```
Server speichert alle 60 s nach `user://server_save.dat`. Trennen macht den Charakter zum NPC (Übergang läuft), Wiederkommen unter demselben Namen loggt in ihn ein. Zeitsprung gibt es online nicht, die Zeit läuft für alle.

## Spielen
`godot --path .` oder Projekt im Editor öffnen. WASD bewegen, Maus zielen, Linksklick angreifen, E halten sammeln/plündern, F essen, H Verband anlegen (3 s, nicht angreifen), Q Waffe wechseln, C Werkbank, B Baumodus (1/2/3 Teil bzw. Kachel beanspruchen, T drehen, Linksklick setzen, X abreißen/freigeben), E neben dem eigenen Anker liefert Holz ab, E neben dem eigenen Turret lädt Kugeln, E (tippen) neben einem Handelstisch öffnet die Handelstafel, neben einem Markt-Depot die Depot-Tafel, E neben dem eigenen Schild beschriftet es, Enter Chat (/g global), M Marker, Esc Ausloggen-Menü, R neuer Charakter nach dem Tod. Im Offline-Modus Knöpfe unten rechts: Zeitsprung, einloggen, gegen sich selbst antreten. Spielstand wird automatisch geführt; 'Neues Spiel' (zweimal klicken) löscht ihn.

## Konventionen
- **Code und Identifier Englisch** (Dateien, Klassen, Variablen, JSON-Schlüssel). **UI-Texte und Chronik Deutsch. Kommentare Deutsch.**
- GDScript: Tabs, `snake_case` für Variablen/Funktionen, `PascalCase` für `class_name`, statische Typisierung überall. Sim-Klassen erben von `RefCounted`. Enum `SimCharacter.Controller` (nicht `Control`: kollidiert mit der Godot-Klasse).
- `.gd.uid`-Dateien werden mit eingecheckt (erzeugt `--import`).
- Heiße Pfade der Sim (Bewegung, Sichtlinie, Wegsuche) laufen zehntausende Male je Zeitsprung: dort keine `range()`-Schleifen, Dictionary-Suchen oder `balf()`-Aufrufe ohne Vorab-Check (Beispiel: `SimMap.built_tiles` vor `built_half`). Bei Änderungen an der Sim die Laufzeit mit `tools/balance_report.gd -- 1 8` vergleichen (Spalte ms Ø, Stand: ≈ 11 s je 8 h).
- Chronik-Zeilen im Format `HH:MM – <Auslöser>, Regel <n>: <Aktion> (<Details>)`, z. B. `05:02 – hungrig, Regel 1: gegessen (Beeren 4→3)`. Texte kommen aus den `log`-Vorlagen in conditions.json/actions.json.
- Commits: ein Commit pro Arbeitsschritt, aussagekräftige Messages auf Deutsch.

## Werkzeuge
- Godot 4.7.2 liegt in `C:\Users\Shiva\Tools`; `godot` (Console-Exe, sauberes stdout) ist im User-PATH. In Git-Bash-Aufrufen aus Claude Code ggf. `export PATH="$PATH:/c/Users/Shiva/Tools"` voranstellen.
- Projekt liegt in `C:\Users\Shiva\Documents\Code\godot`.

## Arbeitsweise
Nach jedem Schritt kurz melden, ein Commit pro Schritt. Antworten kurz halten: Fortschritt zeigen, keine Erklärungen, die im Code stehen könnten.
