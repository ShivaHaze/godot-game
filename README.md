# Prototyp (Arbeitstitel)

Ein 2D-Überlebensspiel, in dem dein Charakter weiterhandelt, wenn du ausloggst: Du gibst ihm Wenn-Dann-Regeln, er
sammelt, wacht, handelt oder versteckt sich, und in der Chronik liest du hinterher, was passiert ist.
Design-Dokument: `docs/design-doc.md`. Für Entwickler: `CLAUDE.md`.

## Spielen (fertige Programme)

Unter **Releases → „Aktueller Build“** (Tag `latest`) liegen bei jedem Stand von `main`:

| Datei | Wofür |
|---|---|
| `Prototyp-Client.exe` | Das Spiel (Windows). Starten, Name und Passwort eingeben, Serveradresse eintragen, „Verbinden“ – oder „Einzelspieler“ mit Zeitsprung. |
| `Prototyp-Server.exe` + `Server-starten.bat` | Server auf einem Windows-Rechner. Doppelklick auf die .bat, Mitspieler tragen deine IP mit `:7777` ein. Port 7777 (UDP) muss erreichbar sein (Router-Freigabe oder gleiches LAN). |
| `prototyp-server.x86_64` + `install-server.sh` | Server auf Ubuntu (z. B. Hetzner): beide Dateien hochladen, `sudo bash install-server.sh` – richtet einen Dienst ein, öffnet den Port in ufw, speichert alle 60 s. |

Steuerung: WASD bewegen, Maus zielen, Linksklick angreifen, E sammeln/plündern/handeln, F essen, H Verband, Q Waffe,
C Herstellen, B Bauen, M Marker, Enter Chat, Esc Ausloggen-Menü, R neuer Charakter nach dem Tod.
Mehrspieler: Trennen macht deinen Charakter zum NPC mit deinen Regeln; wer mit demselben Namen wiederkommt, übernimmt ihn.

## Aus dem Quelltext

Godot 4.7.2: `godot --path .` startet das Spiel, `tools/run_tests.ps1` die Tests, `tools/build.ps1` baut die Programme
nach `build/` (braucht die Export-Vorlagen 4.7.2). Server aus dem Quelltext:
`godot --headless --path . -s server/server_main.gd -- 7777 200 0`.
