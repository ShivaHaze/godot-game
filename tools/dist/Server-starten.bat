@echo off
rem Startet den Spielserver auf diesem Windows-Rechner: Port 7777 (UDP), 200 Offline-Siedler als Fuellung.
rem Die Welt liegt unter %APPDATA%\Godot\app_userdata\Prototyp\world.db (SQLite, alle 10 s die Aenderungen, taeglich eine Sicherung in backups\).
rem Beenden mit Strg+C (speichert vorher). Mitspieler tragen deine IP:7777 im Startbildschirm ein; Konten liegen in accounts.db daneben.
rem Ohne Passwoerter (nur zum Testen): am Ende der Zeile unten "open" anhaengen.
cd /d "%~dp0"
Prototyp-Server.exe --headless -- --server 7777 200
pause
