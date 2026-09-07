# Führt alle GUT-Tests headless aus. Exit-Code 0 = alle Tests grün.
# Aufruf: tools\run_tests.ps1   (aus beliebigem Verzeichnis)
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    # Import-Cache (.godot/) aufbauen – nötig, damit class_name-Klassen headless auflösbar sind.
    godot --headless --path . --import | Out-Null
    godot --headless --path . -s addons/gut/gut_cmdln.gd
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
