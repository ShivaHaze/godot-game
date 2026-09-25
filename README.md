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
sudo bash install-server.sh 7777 10
```

Die Argumente sind `[Port] [Füllung] [Karte]`, alle optional:

| Argument | Standard | Bedeutung |
|---|---|---|
| Port | `7777` | UDP-Port, den Mitspieler hinter der Adresse eintragen (`1.2.3.4:7777`). |
| Füllung | `10` | So viele Offline-Siedler (NPCs ohne Spieler, Rollen Verstecken/Wache/Sammler) setzt der Server in eine **neue** Welt – auf freien Boden, weg von Spieler- und Wolf-Spawns und voneinander, nicht auf Markt, Outpost oder Sumpf. Eine geladene Welt wird nie aufgefüllt, auch nach Updates nicht. Für 5–10 Spieler auf der Standardkarte **0 bis 20** (Empfehlung 10: die Welt wirkt belebt, die Beeren reichen; nach 3 Stunden leben in der Simulation noch 7–9 von 10); 200 leeren alle Beerenbüsche in wenigen Minuten. |
| Karte | beim ersten Mal die Standardkarte 40×30, danach die eingerichtete | `gen:60x45:7` erzeugt eine Karte (Breite×Höhe:Seed), `standard` wählt die Standardkarte 40×30, sonst ein Pfad zu einer Karten-JSON, die der Dienstbenutzer lesen darf (z. B. `/var/lib/prototyp/karte.json`; unter `/root` und `/home` sperrt der Dienst den Zugriff). Für 5–10 Spieler reicht die Standardkarte; größere Karten heißen weniger Begegnungen. |

Die Karte gehört zur Welt: ohne Kartenargument behalten `install-server.sh`, `update-server.sh` und `tools/deploy.sh`
die Karte des eingerichteten Dienstes (`update-server.sh` auch Port und Füllung). Wer die Karte wechseln will, braucht
eine neue Welt (siehe unten) und ruft `install-server.sh` mit der neuen Karte auf, z. B.
`sudo bash install-server.sh 7777 10 gen:60x45:7`.

**Neue Welt, z. B. vor dem Testabend.** Die Füllung wirkt nur in einer neuen Welt; eine Welt, die ein älterer Server
angelegt hat, behält ihre Füll-NPCs (bis Schritt 54 füllte jeder Start bis zur eingestellten Zahl auf, Standard war 200). Auch `update-server.sh` aus einer
älteren Installation übernimmt die alte Füllung 200 – deshalb die Zahl beim Neuanlegen ausdrücklich angeben:

```
sudo systemctl stop prototyp-server
cd /var/lib/prototyp/godot/app_userdata/Prototyp
sudo mkdir -p backups/alte-welt
sudo mv world.db* backups/alte-welt/                    # world.db samt world.db-wal/-shm
sudo mv server_save.dat backups/alte-welt/ 2>/dev/null  # nur falls vorhanden: Spielstand von vor Schritt 52, käme sonst zurück
cd ~ && curl -fsSLO https://github.com/ShivaHaze/godot-game/releases/download/latest/install-server.sh
sudo bash install-server.sh 7777 10
```

Vom Entwicklungsrechner aus nach den ersten fünf Zeilen stattdessen `tools/deploy.sh root@<IP> 7777 10`. Konten
(`accounts.db`) bleiben erhalten – Name und Passwort gelten weiter, die Charaktere beginnen neu.

Das Skript lädt den aktuellen Server-Build selbst, legt den Systembenutzer `prototyp` an, richtet den Dienst
`prototyp-server` ein (startet beim Booten neu, Strg+C bzw. `systemctl stop` speichert), öffnet Port 7777/udp in ufw und
zeigt am Ende die Adresse, die Mitspieler eintragen. Hängt an dem Server eine Hetzner-Cloud-Firewall, dort ebenfalls
UDP 7777 eingehend erlauben. Nützlich danach:

| Befehl | Wirkung |
|---|---|
| `sudo bash /opt/prototyp/update-server.sh` | Neuen Build einspielen: stoppt (speichert), sichert die Welt, tauscht das Programm, startet. |
| `journalctl -u prototyp-server -f` | Log live (Tickzeit, Spieler, Speichern, Sicherungen). |
| `systemctl restart prototyp-server` | Neustart; `stop` speichert die Welt. Wer beim Stopp online war, handelt danach nach seinen Regeln weiter (Chronik: „Server-Neustart“). |
| `ls /var/lib/prototyp/godot/app_userdata/Prototyp/` | `world.db`, `accounts.db`, `backups/` (tägliche Sicherungen plus eine vor jedem Update). |

Vom Entwicklungsrechner aus geht beides in einem Schritt per SSH: `tools/deploy.sh root@<IP> 7777 10 [Karte]` (nimmt
`build/prototyp-server.x86_64`, sonst den Build von GitHub).

## Aus dem Quelltext

Godot 4.7.2: `godot --path .` startet das Spiel, `tools/run_tests.ps1` die Tests, `tools/build.ps1` baut die Programme
nach `build/` (braucht die Export-Vorlagen 4.7.2). Server aus dem Quelltext:
`godot --headless --path . -s server/server_main.gd -- 7777 10 0` (Port, Füllung, Laufzeit in s mit 0 = endlos, optional Karte).
