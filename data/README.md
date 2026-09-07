# data/ – alle Spieldaten als JSON

Kein Code nötig, um hier etwas zu ändern. Schlüssel, die mit `_` beginnen, sind Erklärungen und werden ignoriert.

| Datei | Inhalt |
|---|---|
| `balance.json` | Alle Tuning-Zahlen (Geschwindigkeit, Schaden, Hungerrate, Leinenradius, Tickrate, Wolf, Zeitsprung). |
| `resources.json` | Rohstoffe (Holz, Beeren): Name, essbar, Nährwert. |
| `tiles.json` | Kacheltypen und ihr Zeichen in der Karte; Quellen mit Rohstoff und Vorrat. |
| `map.json` | Die Karte als Zeichenraster plus Spawn-Zeichen (`P` Spieler, `W` Wolf). |
| `conditions.json` | Bedingungen des Regelsystems: welcher Sensorwert wie verglichen wird, welche Parameter der Spieler setzt, Texte für UI und Chronik. |
| `actions.json` | Aktionen des Regelsystems mit Parametern (Ort, Leine, Rohstoff) und Texten. |
| `roles.json` | Rollen-Presets (Verstecken, Wache, Sammler, Händler) als Regellisten, plus das Default-Regelwerk. |

Regelformat (in `roles.json` und im Spielstand):

```json
{ "if": { "condition": "health_below", "params": { "percent": 30 } },
  "then": { "action": "flee_to", "params": { "place": "here", "radius": 2 } } }
```

`place` ist `"here"` (Ausloggen-Position) oder die Kennung eines live gesetzten Markers. Die letzte Regel einer Liste muss die Bedingung `else` ("Sonst") haben.

Alle Dateien werden von `sim/sim_data.gd` geladen und geprüft; Fehler erscheinen beim Start und in den Tests (`tools/run_tests.ps1`).
