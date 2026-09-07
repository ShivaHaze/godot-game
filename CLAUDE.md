# CLAUDE.md – Phase 0: Rechteck-Prototyp

## Projektziel
Ein Single-Player-Prototyp in Godot 4.7.x (GDScript), der genau eine Frage beantwortet: Fühlt sich der Kern-Twist gut an?
Der Twist: Beim "Ausloggen" wird der Spielercharakter zum NPC, der nach vom Spieler festgelegten Wenn-Dann-Regeln weiterhandelt; der Spieler springt 8 Stunden in die Zukunft, findet seinen Charakter vor und liest in der Chronik, was passiert ist.

**Design-Dokument: `docs/design-doc.md`.** Legende dort: **[E]** entschieden (wird nicht diskutiert) · **[T]** Tendenz · **[O]** offen. Abschnitt 8 beschreibt Phase 0 und die beim Bau getroffenen Entscheidungen.
Designfragen, die das Dokument nicht beantwortet: **nicht raten, fragen.** Eigene Entscheidungen, die das Design berühren, dort als [T]/[O] eintragen und Bescheid sagen.

## Stand (2026-09-07)
Schritte 1–8 sind gebaut und committet: Gerüst, Daten, Sim-Kern, Regelmaschine + Chronik, Kampf + Wolf, NPC-Modus, Ausloggen-Menü, Zeitsprung + Gegen-sich-selbst. 90 Tests laufen headless grün. Nächster Schritt laut Design: Abnahmetest durch den Spieler (Gefühl), danach Balancing über `data/balance.json`.

## Scope Phase 0 (nichts darüber hinaus ohne Rückfrage)
- Karte aus Datendatei (Kacheln: Boden, Hindernis, Holzquelle, Beerenbusch). Rechtecke, keine Grafik.
- Spieler: WASD, Twin-Stick-Schuss (Maus), 1–3 langsame sichtbare Projektile, Richtungstreffer (hinten/seitlich = mehr Schaden), HP, flacher Rüstungsabzug als Parameter.
- Inventar: Holz, Beeren. Sammeln per Interaktion. Leichen sind plünderbar.
- Hunger als Unterhalt: sinkt langsam, bei 0 geschwächt (halbe Geschwindigkeit), nicht tot.
- Wolf-KI: nähert sich, beißt, flieht bei niedrigem HP, kommt nach.
- Ausloggen-Menü: 4 Rollen-Presets (Verstecken, Wache, Sammler, Händler-Platzhalter), jede Rolle = vorausgefüllte, aufklappbare, editierbare Regelliste.
- Regelsystem: Prioritätenliste, erste zutreffende (und ausführbare) Regel gewinnt, letzte Zeile immer "Sonst". Startvokabular exakt wie im Design: Bedingungen *Leben < X %, hungrig, wird angegriffen, Fremder in Nähe [Radius], Inventar voll/leer*; Aktionen *fliehe zu [Ort], bleib bei [Ort], sammle [Rohstoff] um [Ort], iss, kämpfe zurück, verstecken*. Kein "greife an".
- Marker + Leine: Marker live per Taste (M); nur Marker plus "Hier" sind als [Ort] wählbar; jede Ortsregel hat einen Radius, sichtbar als Kreis (auch als Vorschau im Menü); der NPC verlässt die Leine nie.
- NPC-Modus: gleiches Kampfsystem wie der Spieler, aber schlechter (zielt auf aktuelle statt zukünftige Position, dreht sich zur Bedrohung, handelt vorsichtig).
- Chronik: jede gefeuerte Regel mit Zeitstempel, beim Zurückkommen lesbar.
- Zeitsprung "8 Stunden überspringen" = Sim ticken ohne zu zeichnen (grob ohne Gefahr, fein bei Kampf).
- Gegen-sich-selbst-Modus: frischer Charakter (Besitzer p2) gegen den eigenen NPC von "gestern".

**Nicht im Scope:** Netzwerk, Bauen, Claims, Gilden, Handel, weitere Rohstoffe, Zustandseffekte, Grafik, Sound, Setting, Logout-Übergang. Keine Assets, keine Addons außer GUT. Alles sind ColorRects, Linien und Labels.

## Architektur-Vorgaben (nicht verhandelbar)
1. **Simulation getrennt von Darstellung.** Alles, was den Weltzustand verändert (Bewegung, Kampf, Hunger, Regeln, Sammeln), lebt in `sim/` und läuft mit festem Tick (20 Hz). `sim/` verwendet keine Nodes, keine Szenen, keine Autoloads, kein `get_tree()`, kein `Input` – nur `RefCounted`-Klassen und reine Daten. `game/` liest den Sim-Zustand nur aus, zeichnet und schreibt ausschließlich `SimIntent`s hinein. Grund: Die Sim läuft später unverändert auf einem Godot-headless-Server. Zeitsprung = `SimWorld.advance()`.
2. **Datengetrieben.** Regel-Bausteine (Bedingungen, Aktionen), Rollen-Presets, Rohstoffe, Karte und Balancing liegen als JSON unter `data/`. Eine neue Bedingung ist ein Eintrag in `conditions.json` (Sensorwert + Vergleich); die Regelmaschine bleibt unverändert (per Test belegt). Ein neuer Sensorwert ist eine Zeile in `sim/sim_sensors.gd`.
3. **Regelmaschine als reine Logik.** `RuleEngine.evaluate(rules, facts, data)`: Eingabe Sensorwerte + Regelliste, Ausgabe erste zutreffende Regel. Testbar ohne Szene.
4. **Tests für die Sim** laufen headless (GUT). Abgedeckt: Regelmaschine (Priorität, Sonst-Fallback, Leine), Hunger-Tick, Richtungstreffer, Karte/Kollision/Wegsuche, Kampf, Wolf, NPC-Controller, Zeitsprung, Determinismus, Menü und Hauptszene.
5. **Balancing sichtbar.** Alle Tuning-Werte in `data/balance.json` (mit `_`-Erklärungen), ohne Code-Kenntnis editierbar. Pflichtschlüssel werden beim Laden geprüft (`SimData.REQUIRED_BALANCE`).
6. **Determinismus.** Die Sim nutzt einen eigenen, geseedeten `RandomNumberGenerator` (kein globales `randi()`); gleicher Seed = gleicher Zeitsprung (per Test belegt).

**Warum JSON statt Godot-Resources:** ohne Editor les- und editierbar, diffbar in Git, keine `class_name`-Registrierung nötig, identisches Laden auf Client und headless-Server. Typprüfung übernimmt `sim/sim_data.gd`.

## Ordnerstruktur
```
project.godot        Godot-Projekt (Input-Map: move_*, shoot, interact, eat, place_marker, logout_menu, respawn)
CLAUDE.md            diese Datei
docs/design-doc.md   Design-Dokument (Wahrheit für alle Designfragen)
data/                JSON: balance, resources, tiles, map, conditions, actions, roles (+ README.md)
sim/                 Simulation ohne Nodes:
  sim_data.gd          Loader + Validierung + Regel-Normalisierung + Textvorlagen
  sim_world.gd         Weltzustand, Tick/step(dt), Intents, Kampf, Hunger, Sammeln, Plündern, Verstecken,
                       Wölfe, logout()/login(), advance()/advance_until() (Zeitsprung), is_hot()
  sim_map.gd           Karte, Kollision (Kreis vs. Kacheln, Gleiten, Substeps), Quellen, A*
  sim_character.gd     Charakterdaten (Spieler live / NPC / Wolf)
  sim_intent.gd        Steuerabsicht pro Tick (move, aim, shoot, interact, eat, hide, melee)
  sim_projectile.gd, sim_resource_node.gd   Daten
  sim_combat.gd        Richtungstreffer + Rüstung (reine Logik)
  sim_sensors.gd       Sensorwerte ("facts") für die Regelmaschine
  rule_engine.gd       Regelmaschine (reine Logik)
  sim_chronicle.gd     Chronik-Einträge und -Texte
  npc_controller.gd    Offline-Modus: Regelliste ausführen, Leine, Aktionen
  wolf_ai.gd           Wolf-Verhalten
  sim_nav.gd           Wegfolge (A*, Sichtlinie, kein Überschießen bei groben Ticks)
game/                Darstellung und Eingabe (liest sim/, schreibt nur Intents):
  main.gd/.tscn        Modi Live / Menü / Offline / Zeitsprung / Versus, Tick-Akkumulator, Kamera
  world_view.gd        Zeichnet Karte, Quellen, Charaktere, Projektile, Marker, Leinen (interpoliert)
  hud.gd               Status, Hinweise, Meldungen, Chronik-Tafel, Knopfleiste
  logout_menu.gd       Rollen + Regel-Editor, aus den Daten gebaut
tests/unit/          GUT-Tests (test_*.gd)
tools/               run_tests.ps1 / run_tests.sh (headless), smoke_run.gd (Rauchtest mit Fenster)
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

## Spielen
`godot --path .` oder Projekt im Editor öffnen. WASD bewegen, Maus zielen, Linksklick schießen, E halten sammeln/plündern, F essen, M Marker, Esc Ausloggen-Menü, R neuer Charakter nach dem Tod. Im Offline-Modus Knöpfe unten rechts: Zeitsprung, einloggen, gegen sich selbst antreten.

## Konventionen
- **Code und Identifier Englisch** (Dateien, Klassen, Variablen, JSON-Schlüssel). **UI-Texte und Chronik Deutsch. Kommentare Deutsch.**
- GDScript: Tabs, `snake_case` für Variablen/Funktionen, `PascalCase` für `class_name`, statische Typisierung überall. Sim-Klassen erben von `RefCounted`. Enum `SimCharacter.Controller` (nicht `Control`: kollidiert mit der Godot-Klasse).
- `.gd.uid`-Dateien werden mit eingecheckt (erzeugt `--import`).
- Chronik-Zeilen im Format `HH:MM – <Auslöser>, Regel <n>: <Aktion> (<Details>)`, z. B. `05:02 – hungrig, Regel 1: gegessen (Beeren 4→3)`. Texte kommen aus den `log`-Vorlagen in conditions.json/actions.json.
- Commits: ein Commit pro Arbeitsschritt, aussagekräftige Messages auf Deutsch.

## Werkzeuge
- Godot 4.7.2 liegt in `C:\Users\Shiva\Tools`; `godot` (Console-Exe, sauberes stdout) ist im User-PATH. In Git-Bash-Aufrufen aus Claude Code ggf. `export PATH="$PATH:/c/Users/Shiva/Tools"` voranstellen.
- Projekt liegt in `C:\Users\Shiva\Documents\Code\godot`.

## Arbeitsweise
Nach jedem Schritt kurz melden, ein Commit pro Schritt. Antworten kurz halten: Fortschritt zeigen, keine Erklärungen, die im Code stehen könnten.
