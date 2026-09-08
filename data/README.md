# data/ – alle Spieldaten als JSON

Kein Code nötig, um hier etwas zu ändern. Schlüssel, die mit `_` beginnen, sind Erklärungen und werden ignoriert.

| Datei | Inhalt |
|---|---|
| `balance.json` | Alle Tuning-Zahlen (Geschwindigkeit, Schaden, Hungerrate, Leinenradius, Tickrate, Wolf, Zeitsprung). |
| `resources.json` | Rohstoffe (Holz, Beeren, Stein, Fasern …) und Verbrauchsgüter mit `cost` (Stoff aus Fasern; Verband aus Stoff: `heal`, `heal_time`); `needs_building` = Station, die beim Herstellen in Reichweite stehen muss (Lagerfeuer, Werkbank, Schmelzofen, Schmiede). |
| `tiles.json` | Kacheltypen und ihr Zeichen in der Karte; Quellen mit Rohstoff und Vorrat (`offline_needs`: Bauteil, das Offline-Charaktere daneben brauchen, z. B. Mine); `zone` (Marktboden). |
| `map.json` | Die Karte als Zeichenraster plus Spawn-Zeichen (`P` Spieler, `W` Wolf, `D` Markt-Depot auf Marktboden `M`). |
| `conditions.json` | Bedingungen des Regelsystems: welcher Sensorwert wie verglichen wird, welche Parameter der Spieler setzt, Texte für UI und Chronik. |
| `actions.json` | Aktionen des Regelsystems mit Parametern (Ort, Leine, Rohstoff, Erzeugnis, Sensor) und Texten; optional `unlock` {fact, label} für gesperrte Bausteine. |
| `roles.json` | Rollen-Presets (Verstecken, Wache, Sammler, Händler) als Regellisten, plus das Default-Regelwerk. |
| `items.json` | Ausrüstung: Waffen (Fern-/Nahkampf, `ammo`, `effect`, `breaks`) und Rüstung (`armor`, `slow`; wird explizit angelegt), jeweils mit Kosten, `durability` und `needs_building` (Werkbank oder Schmiede; ohne Eintrag von Hand). |
| `buildings.json` | Bauteile: Größe in Halbzellen, Kosten, Lebenspunkte, Durchlässigkeit (none/owner/all), Verfall je Stunde; Sonderrollen über Flags (`trade`, `sensor_radius`, `trap_damage`, `sign`, `spawn`, `depot`, `station`, `next_to_resource`, `claim_only`, `one_per_owner`, `placeable`, `indestructible`). |

Regelformat (in `roles.json` und im Spielstand):

```json
{ "if": { "condition": "health_below", "params": { "percent": 30 } },
  "then": { "action": "flee_to", "params": { "place": "here", "radius": 2 } } }
```

`place` ist `"here"` (Ausloggen-Position) oder die Kennung eines live gesetzten Markers. Die letzte Regel einer Liste muss die Bedingung `else` ("Sonst") haben.

Alle Dateien werden von `sim/sim_data.gd` geladen und geprüft; Fehler erscheinen beim Start und in den Tests (`tools/run_tests.ps1`).
