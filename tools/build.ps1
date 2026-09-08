# Baut Client und Server als eigenständige Programme nach build/ (Windows-Client, Windows-Server, Linux-Server).
# Voraussetzung: Godot 4.7.2 als `godot` im PATH (oder -Godot <Pfad>) und die Export-Vorlagen 4.7.2 unter
# %APPDATA%\Godot\export_templates\4.7.2.stable\ (Godot-Editor: Editor > Export-Vorlagen verwalten, oder tools/install_templates.ps1).
# Aufruf: tools\build.ps1 [-Godot C:\Pfad\zu\godot_console.exe]
param([string]$Godot = "godot")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
New-Item -ItemType Directory -Force build | Out-Null
& $Godot --headless --path . --import
& $Godot --headless --path . --export-release "Windows Client" build/Prototyp-Client.exe
& $Godot --headless --path . --export-release "Windows Server" build/Prototyp-Server.exe
& $Godot --headless --path . --export-release "Linux Server" build/prototyp-server.x86_64
Copy-Item tools/dist/* build/ -Force
Get-ChildItem build | Format-Table Name, Length
