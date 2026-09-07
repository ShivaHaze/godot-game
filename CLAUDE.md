# CLAUDE.md – Phase 0: Rechteck-Prototyp

## Projektziel
Ein Single-Player-Prototyp in Godot 4.7.x (GDScript), der genau eine Frage beantwortet: Fühlt sich der Kern-Twist gut an?
Der Twist: Beim "Ausloggen" wird der Spielercharakter zum NPC, der nach vom Spieler festgelegten Wenn-Dann-Regeln weiterhandelt; der Spieler springt 8 Stunden in die Zukunft, findet seinen Charakter vor und liest in der Chronik, was passiert ist.

**Design-Dokument: `docs/design-doc.md`.** Legende dort: **[E]** entschieden (wird nicht diskutiert) · **[T]** Tendenz · **[O]** offen. Abschnitt 8 beschreibt Phase 0.
Designfragen, die das Dokument nicht beantwortet: **nicht raten, fragen.** Eigene Entscheidungen, die das Design berühren, dort als [T]/[O] eintragen und Bescheid sagen.

## Scope Phase 0 (nichts darüber hinaus ohne Rückfrage)
- Karte aus Datendatei (Kacheln: Boden, Hindernis, Holzquelle, Beerenbusch). Rechtecke, keine Grafik.
- Spieler: WASD, Twin-Stick-Schuss (Maus), 1–3 langsame sichtbare Projektile, Richtungstreffer (hinten/seitlich = mehr Schaden), HP, flacher Rüstungsabzug als Parameter.
- Inventar: Holz, Beeren. Sammeln per Interaktion.
- Hunger als Unterhalt: sinkt langsam, bei 0 geschwächt (halbe Geschwindigkeit), nicht tot.
- Wolf-KI: nähert sich, beißt, flieht bei niedrigem HP.
- Ausloggen-Menü: 4 Rollen-Presets (Verstecken, Wache, Sammler, Händler-Platzhalter ohne Funktion), jede Rolle = vorausgefüllte, aufklappbare, editierbare Regelliste.
- Regelsystem: Prioritätenliste, erste zutreffende Regel gewinnt, letzte Zeile immer "Sonst". Startvokabular exakt wie im Design: Bedingungen *Leben < X %, hungrig, wird angegriffen, Fremder in Nähe [Radius], Inventar voll/leer*; Aktionen *fliehe zu [Ort], bleib bei [Ort], sammle [Rohstoff] um [Ort], iss, kämpfe zurück, verstecken*. Kein "greife an".
- Marker + Leine: Marker live per Taste setzen; nur Marker plus "Hier" sind als [Ort] wählbar; jede Ortsregel hat einen Radius, sichtbar als Kreis; der NPC verlässt die Leine nie.
- NPC-Modus: gleiches Kampfsystem wie der Spieler, aber schlechter (zielt auf aktuelle statt zukünftige Position, dreht sich zur Bedrohung, handelt vorsichtig).
- Chronik: jede gefeuerte Regel mit Zeitstempel, beim Zurückkommen lesbar.
- Zeitsprung "8 Stunden überspringen" = Sim N-mal ticken ohne zu zeichnen.
- Gegen-sich-selbst-Modus: frischer Charakter gegen den eigenen NPC von "gestern".

**Nicht im Scope:** Netzwerk, Bauen, Claims, Gilden, Handel, weitere Rohstoffe, Zustandseffekte, Grafik, Sound, Setting. Keine Assets, keine Addons außer GUT. Alles sind ColorRects, Linien und Labels.

## Architektur-Vorgaben (nicht verhandelbar)
1. **Simulation getrennt von Darstellung.** Alles, was den Weltzustand verändert (Bewegung, Kampf, Hunger, Regeln, Sammeln), lebt in `sim/` und läuft mit festem Tick (20 Hz). `sim/` verwendet keine Nodes, keine Szenen, keine Autoloads, kein `get_tree()` – nur `RefCounted`-Klassen und reine Daten. `game/` liest den Sim-Zustand nur aus und zeichnet. Grund: Die Sim läuft später unverändert auf einem Godot-headless-Server. Zeitsprung = Sim N-mal ticken ohne zu zeichnen.
2. **Datengetrieben.** Regel-Bausteine (Bedingungen, Aktionen), Rollen-Presets, Rohstoffe, Karte und Balancing liegen als JSON unter `data/`. Eine neue Bedingung hinzuzufügen darf keine Änderung an der Regelmaschine erfordern.
3. **Regelmaschine als reine Logik.** Eingabe: Weltzustand + Regelliste eines Charakters. Ausgabe: eine Aktion. Testbar ohne Szene.
4. **Tests für die Sim** laufen headless (GUT). Mindestens: Regelmaschine (Priorität, Sonst-Fallback, Leine), Hunger-Tick, Richtungstreffer.
5. **Balancing sichtbar.** Alle Tuning-Werte (Geschwindigkeit, Schaden, Hungerrate, Leinenradius, Tickrate …) in `data/balance.json`, ohne Code-Kenntnis editierbar.
6. **Determinismus.** Die Sim nutzt einen eigenen, geseedeten `RandomNumberGenerator` (kein globales `randi()`), damit Zeitsprung und Tests reproduzierbar sind.

**Warum JSON statt Godot-Resources:** ohne Editor les- und editierbar, diffbar in Git, keine `class_name`-Registrierung nötig, identisches Laden auf Client und headless-Server. Typprüfung übernimmt der Loader in `sim/` (Fehlformate werden getestet).

## Ordnerstruktur
```
project.godot        Godot-Projekt (Input-Map: move_*, shoot, interact, eat, place_marker, logout_menu)
CLAUDE.md            diese Datei
docs/design-doc.md   Design-Dokument (Wahrheit für alle Designfragen)
data/                JSON-Daten: Karte, Rohstoffe, Bedingungen, Aktionen, Rollen, balance.json
sim/                 Simulation, tickbasiert, ohne Nodes (Welt, Karte, Entities, Kampf, Hunger, Regelmaschine, Chronik)
game/                Godot-Szenen und -Skripte: Darstellung, Eingabe, UI (liest sim/, schreibt nie direkt)
tests/unit/          GUT-Tests (test_*.gd), vor allem für sim/
tools/               run_tests.ps1 / run_tests.sh
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

## Konventionen
- **Code und Identifier Englisch** (Dateien, Klassen, Variablen, JSON-Schlüssel). **UI-Texte und Chronik Deutsch. Kommentare Deutsch.**
- GDScript: Tabs, `snake_case` für Variablen/Funktionen, `PascalCase` für `class_name`, statische Typisierung überall. Sim-Klassen erben von `RefCounted`.
- Ein Godot-Projekt-Skript pro Datei; `.gd.uid`-Dateien werden mit eingecheckt.
- Chronik-Zeilen im Format `HH:MM – <Auslöser>, Regel <n>: <Aktion> (<Details>)`, z. B. `05:02 – hungrig, Regel 1: gegessen (Beeren 4→3)`.
- Commits: ein Commit pro Arbeitsschritt, aussagekräftige Messages auf Deutsch.

## Werkzeuge
- Godot 4.7.2 liegt in `C:\Users\Shiva\Tools`; `godot` (Console-Exe, sauberes stdout) ist im User-PATH.
- Projekt liegt in `C:\Users\Shiva\Documents\Code\godot`.

## Arbeitsweise
Reihenfolge, nach jedem Schritt kurz melden, ein Commit pro Schritt:
1. Projektgerüst + CLAUDE.md + Test-Setup
2. Datenformate und Beispieldaten
3. Sim-Kern mit Tick, Karte, Bewegung, Hunger, Sammeln
4. Regelmaschine + Chronik mit Tests
5. Kampf mit Richtungstreffer, Wolf
6. NPC-Modus
7. Ausloggen-Menü mit Rollen, Regel-Editor, Marker, Leine
8. Zeitsprung + Gegen-sich-selbst-Modus

Antworten kurz halten: Fortschritt zeigen, keine Erklärungen, die im Code stehen könnten.
