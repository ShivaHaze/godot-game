@echo off
rem Startet den Spielserver auf diesem Windows-Rechner: Port 7777 (UDP), 200 Offline-Siedler als Fuellung.
rem Der Spielstand liegt unter %APPDATA%\Godot\app_userdata\Prototyp\server_save.dat und wird alle 60 s geschrieben.
rem Beenden mit Strg+C (speichert vorher). Mitspieler tragen deine IP:7777 im Startbildschirm ein.
cd /d "%~dp0"
Prototyp-Server.exe --headless -- --server 7777 200
pause
