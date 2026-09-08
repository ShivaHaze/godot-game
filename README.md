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
| `prototyp-server.x86_64` + `install-server.sh` + `update-server.sh` | Server auf Ubuntu (z. B. Hetzner), siehe unten. |

Steuerung: WASD bewegen, Maus zielen, Linksklick angreifen, E sammeln/plündern/handeln, F essen, H Verband, Q Waffe,
C Herstellen, B Bauen, M Marker, Enter Chat, Esc Ausloggen-Menü, R neuer Charakter nach dem Tod.
Der Server hält die Welt in einer SQLite-Datei (`world.db`, alle 10 s die Änderungen, täglich eine Sicherung im Ordner `backups/`) und die Konten in `accounts.db`; unter Windows liegen sie in `%APPDATA%\Godot\app_userdata\Prototyp`, unter Ubuntu in `/var/lib/prototyp/godot/app_userdata/Prototyp`.
Mehrspieler: Beim ersten Beitritt legst du mit Name und Passwort dein Konto an (Passwort mindestens 4 Zeichen, gut merken – es gibt keine Wiederherstellung). Trennen macht deinen Charakter zum NPC mit deinen Regeln; wer mit demselben Namen und Passwort wiederkommt, übernimmt ihn.

## Server auf Ubuntu (Hetzner)

Einmalig auf einem frischen Ubuntu (22.04 oder 24.04), als root oder mit sudo:

```
curl -fsSLO https://github.com/ShivaHaze/godot-game/releases/download/latest/install-server.sh
sudo bash install-server.sh 7777 200
```

Das Skript lädt den aktuellen Server-Build selbst, legt den Systembenutzer `prototyp` an, richtet den Dienst
`prototyp-server` ein (startet beim Booten neu, Strg+C bzw. `systemctl stop` speichert), öffnet Port 7777/udp in ufw und
zeigt am Ende die Adresse, die Mitspieler eintragen. Hängt an dem Server eine Hetzner-Cloud-Firewall, dort ebenfalls
UDP 7777 eingehend erlauben. Nützlich danach:

| Befehl | Wirkung |
|---|---|
| `sudo bash /opt/prototyp/update-server.sh` | Neuen Build einspielen: stoppt (speichert), sichert die Welt, tauscht das Programm, startet. |
| `journalctl -u prototyp-server -f` | Log live (Tickzeit, Spieler, Speichern, Sicherungen). |
| `systemctl restart prototyp-server` | Neustart; `stop` speichert die Welt. |
| `ls /var/lib/prototyp/godot/app_userdata/Prototyp/` | `world.db`, `accounts.db`, `backups/` (tägliche Sicherungen plus eine vor jedem Update). |

Vom Entwicklungsrechner aus geht beides in einem Schritt per SSH: `tools/deploy.sh root@<IP> 7777 200` (nimmt
`build/prototyp-server.x86_64`, sonst den Build von GitHub).

## Aus dem Quelltext

Godot 4.7.2: `godot --path .` startet das Spiel, `tools/run_tests.ps1` die Tests, `tools/build.ps1` baut die Programme
nach `build/` (braucht die Export-Vorlagen 4.7.2). Server aus dem Quelltext:
`godot --headless --path . -s server/server_main.gd -- 7777 200 0`.
