# Design-Dokument (Arbeitstitel: offen)

Stand: 2026-09-07 (v5) · Status-Legende: **[E]** entschieden · **[T]** Tendenz · **[O]** offen

## 1. Kern in einem Satz
Echtzeit-2D-PvPvE in einer persistenten Welt, in der dein Charakter beim Ausloggen nicht verschwindet, sondern nach den Regeln weiterhandelt, die du ihm gegeben hast.

## 2. Der Twist
- Online: du steuerst den Charakter live. Offline: er wird zum NPC und führt dein Regelwerk aus.
- Die "neutralen NPCs" der Welt sind überwiegend Offline-Spieler.
- **Offline kann Halten und Erhalten** (verteidigen, handeln, sammeln, produzieren, fliehen, essen, verbinden). **Nur Live kann Nehmen und Verändern** (Wände brechen, bauen, Anker setzen, Schwefel sammeln, neue Gebiete betreten, Gildenverträge).
- Immer ein Default-Regelwerk (iss bei Hunger, flieh bei Angriff, bleib sonst). Kein Zwang, das Menü je zu öffnen.
- **Logout-Übergang (Lehre aus Mortal Online 2):** Ausloggen macht nie sofort sicher. 30–60 s Übergang, in dem der Charakter normal verwundbar ist; im Kampf (Schaden in den letzten 60 s) startet der Übergang erst danach. In fremdem Claim kann kein Offline-Charakter aktiviert werden – er wird zur Claim-Grenze geschoben. Kein Combat-Logging, kein Ninja-Logging in fremde Basen.
- **Simulationsstufen (Lehre aus Screeps):** Offline-Charaktere ohne Online-Spieler in Reichweite laufen grob (z. B. 1 Tick/s, vereinfachte Regeln), bei Annäherung fein (voller Tick). Architektur-Voraussetzung von Tag 1, entscheidet über Serverkosten.
- **Chronik:** Der NPC protokolliert jede gefeuerte Regel mit Zeitstempel ("03:14 – angegriffen, geflohen zu Basis"). Lesbar beim Einloggen. Gleiches auf Gildenebene. Ist Tutorial, Debug-Werkzeug und Geschichtenquelle zugleich.
- Vermutete Lücke: Rust (Offline-Schlafen ohne Verhalten), Screeps (Verhalten ohne Live-Ich), Loop Hero/Autonauts (Idle-Regeln ohne PvP). Schnittmenge unbelegt – vor Prototyp recherchieren.

## 3. Entschieden [E]

### Welt & Struktur
- 2D top-down, Echtzeit. Keine Rundenlogik im Live-Spiel.
- PvPvE mit neutralen/freundlichen Spielern und NPCs.
- Eine große Karte pro Server, ~200–300 Spieler, server-autoritativ, 24/7 simuliert.
- Karten datengetrieben (Ressourcen, Engstellen, Startpunkte, Spawn-Zonen) → seedbar/tauschbar. Karte ist das Balancing-Instrument.
- Kein Reset. Welten haben Lebenszyklus (neue öffnen, alte zerfallen). Wipe-Vorbehalt in Early Access, explizit kommuniziert.
- Spawn in gewichteten Spawn-Zonen (Neulinge → ruhiger, nicht garantiert). Gilden-Claims können teure Spawn-Anker haben → Mitglieder spawnen dort.
- Nur offizielle Server.

### Tod & Progression
- Tod = Charakter weg, alles Zeug bleibt liegen. Leben offen lang.
- Offline killbar/bestehlbar, wehrt sich per Regelwerk.
- Account-gebunden und todesfest: Regel-Vokabular, Gildenrang, Kosmetik. Kein Charakter-Level, keine Stats.
- Regel-Bausteine werden freigeschaltet, wenn ihre Grundbedingung je erfüllt wurde (Prädikat: "hat je Turret besessen", "ist in Gilde", "hat Vergiftung überlebt"). Kein Loot. Das Vokabular eines Spielers ist seine Biografie.
- Gefühl Minute 1: Gier, dann Angst. Tiefe: Builds > Räumliches > Risikoabwägung > Timing.

### Regelsystem
- Wenn-Dann als Prioritätenliste (erste zutreffende gewinnt), frei kombinierbar.
- Start ~3 Bedingungen / ~3 Aktionen; Vokabular wächst über Freischaltungen.
- Regelwerk anderer ist komplett verborgen; Lesen durch Beobachtung ist Kern-PvP-Fähigkeit.
- NPC nutzt dasselbe Kampfsystem, aber schlechter: zielt auf aktuelle statt zukünftige Position, dreht sich zur Bedrohung (umlaufbar), handelt vorsichtig.
- Gilden haben dieselbe Regelmechanik für Rechte ("Mitglied < 3 Tage → kein Lagerzugriff", "beschädigt Anker → Ausschluss, NPCs feindlich"). Gildenführung ist ein Build.
- Sensoren liefern Bedingungen über Distanz ("Sensor Nordtor ausgelöst → geh zu Nordtor").
- **Oberfläche = Rollen, darunter = Regeln.** Neuling wählt eine Rolle (Verstecken, Wache, Sammler, Händler) mit einem Tipp; jede Rolle ist eine vorausgefüllte Regelliste, die man aufklappen und editieren kann ("Advanced"). Trennt Casual von Pro ohne zwei Systeme.
- **Startvokabular.** Bedingungen: Leben < X %, hungrig, wird angegriffen, Fremder in Nähe (Radius), Inventar voll/leer. Aktionen: fliehe zu [Ort], bleib bei [Ort], sammle [Rohstoff] um [Ort], iss, kämpfe zurück, verstecken. "Greife an" NICHT im Start – Offline-Charakter wehrt sich, schlägt nie zuerst zu; Aggression wird freigeschaltet (z. B. nachdem man selbst von einem NPC angegriffen wurde). Handel kommt mit dem Handelstisch. Keine Zeitbedingungen im Start.
- **Default-Regelwerk** (ohne je ins Menü zu gehen): hungrig → iss; angegriffen → fliehe zu [Hier]; sonst → bleib bei [Hier].
- **Orte = Marker + Leine.** Nur live gesetzte Marker (Default: "Hier" = Ausloggen-Position) sind in Regeln verwendbar. Jede Ortsregel hat einen Radius, sichtbar als Kreis vor dem Ausloggen; der NPC verlässt die Leine nie. Vorhersagbarkeit vor Autonomie – Tode müssen sich fair anfühlen.
- **Ausloggen ist die erste Risikoentscheidung:** Verstecken (unsichtbar bis jemand drüberläuft; kein Risiko, kein Ertrag) · Basis (Risiko = Basissicherheit, kein Ertrag) · Sammeln/Handeln/Liefern (sichtbar; Risiko hoch, Ertrag hoch).

### Kampf
- Twin-Stick, wenige langsame sichtbare Projektile (1–3 pro Kämpfer). Kein Bullet-Hell.
- Nahkampf (kurz, hoher Schaden) + Fernkampf (Vorlauf). 4–6 Waffen mit klarer Rolle.
- TTK: Basis schnell (~3 Treffer nackt). Rüstung = flacher Abzug pro Treffer → schwache Waffen prallen ab, starke bleiben gefährlich. Rüstung ist die Investition in den Offline-Schlaf.
- Keine Trefferzonen. Stattdessen **Richtungstreffer**: von hinten/seitlich mehr Schaden bzw. Rüstung teilweise ignoriert. Zielen = Positionierung.
- Zustandseffekte ignorieren Rüstung, je einer Quelle und einem Gegenmittel zugeordnet: Blutung (Klingen ↔ Verband), Verlangsamung (Kälte/Nässe/schwere Rüstung), Vergiftung (Sumpf/Kräutergift ↔ Gegenmittel), Brand (Schwefel), Erschöpfung (Hunger).
- Heilung = Kanalisierung: dauert X s, kein Angreifen währenddessen, Laufen ja. Gleich im und außerhalb des Kampfs.

### Wirtschaft & Überleben
- Geschlossene Spielerwirtschaft: alle Items stammen von Spielern.
- 9 Rohstoffe, jeder mit eigener Zone, Sammelart und exklusiver Funktion:

| Rohstoff | Zone | Sammelbar | Gatet |
|---|---|---|---|
| Holz | überall | offline | Gebäude, Brennstoff, Kupferschmelze |
| Stein | überall | offline | Gebäude, Werkzeuge Stufe 0 |
| Fasern | überall | offline | Stoff → Rüstung, Verbände, Seile/Fallen |
| Nahrung | überall, besser innen | offline | Unterhalt; gekocht = besser |
| Kupfer | Rand | offline | Werkzeuge/Waffen Stufe 1 (weich), Elektrik/Sensoren |
| Eisenerz | Mitte | offline nur mit Mine | Werkzeuge/Waffen Stufe 2, Turrets, Eisenbau |
| Kohle | Mitte | offline nur mit Mine | Schmelzen von Eisen (Engpass), Brennstoff |
| Schwefel | Zentrum | **nur live** | Pulver → Munition, Sprengsätze |
| Kräuter | zonengebunden (Sumpf/Wald/Höhle) | offline | starke Medizin, Gifte |

- Prinzip: Kohle ist der Engpass, nicht Erz (Handel + Kriegsziel). Schwefel nur live → Raidfähigkeit kann nicht idle gefarmt werden.
- Ketten (2–3 Stufen, jede ein Regel-Baustein): Erz+Kohle→Eisen→Werkzeuge/Waffen/Turrets · Schwefel+Kohle→Pulver→Munition/Sprengsatz · Fasern→Stoff→Rüstung/Verbände · Nahrung→gekocht · Holz+Stein→Gebäude, +Eisen→verstärkt · Kräuter→Medizin/Gift · Kupfer→Draht→Sensoren.
- Medizin: Basis aus Ketten (Verbände, Desinfektion), starke Mittel aus Kräutern.
- Senken: Verbrauch (Munition, Essen, Medizin), Verschleiß (Reparatur nie 100 % → alles stirbt irgendwann), Unterhalt (Claims, Charaktere), Verrotten liegengelassener Items nach Tagen.
- Überleben als Unterhalt, nicht Minispiel: Nahrung/Wärme als Tagesverbrauch, offline stark verlangsamt. Mangel → geschwächt, nicht tot. Krankheit als Ereignis.

### Bauen
- Freie Platzierung mit Snapping auf feines Raster: **½ Kachel** (entschieden 2026-09-07). Bauteile belegen Halbzellen; die Wegsuche bleibt auf Kacheln und gilt eine Kachel als blockiert, sobald eine Halbzelle darin bebaut ist. Claims bleiben kachelbasiert.
- Jedes Bauteil einzeln zerstörbar. Stufen: Holz (Nahkampfwerkzeug, verfällt schnell) < Stein (Eisenwerkzeug oder Sprengsatz) < Eisen (nur Sprengsatz).
- Verteidigungsobjekte: Turrets, Fallen, Sensoren – alle regelgesteuert.

### Land (Claims)
1. **Anker + Fläche:** Anker nur live baubar. Kacheln nur zusammenhängend vom Anker aus, keine Inseln/Korridore. Claims überlappen nie.
2. **Unterhalt überproportional:** Kosten pro Kachel steigen mit Fläche. Unterhalt wird *physisch* am Anker abgeliefert (NPC-lieferbar, abschneidbar).
3. **Was ein Claim gibt:** Nur Eigentümer bauen. Eigentümer-NPCs setzen Regeln gegen Fremde durch (Zoll, Zutritt, Angriff). Rohstoffknoten nur für Eigentümer-NPCs; Fremde live = Diebstahl. Spawn-Anker als teures Upgrade.
4. **Verlust stufenweise:** Fehlender Unterhalt → Claim schrumpft von außen über Tage, Gebäude darauf verfallen. Anker live zerstört → Kacheln nach Schonfrist (Stunden) frei, Angreifer kann eigenen Anker setzen.
- Solo-Anker: harte Obergrenze (~30–50 Kacheln). Gilden legen Anker zusammen, Obergrenze skaliert mit Gildenlevel, Unterhalt aus Gildentopf.

### Gilden
- Unbegrenzte Größe, Gilde regelt sich selbst. Verrat möglich (stehlen, Regeln umgehen, Anker sprengen). Rechte über Gilden-Regeln, nicht über Admin-Panel.
- Gilde = Summe der Offline-Charaktere. Gildenlevel steigt durch gemeinschaftliche Offline-Leistung.
- Schaltet frei: Regel-Ausdruckskraft, Regeln zwischen Mitgliedern (Loot-Ketten), geteilter Alarm, mehr Land pro Kopf.
- Königreiche emergent (viel Land, Bündnisse). Kein Verwaltungsmodus.
- Zerg-Bremsen: überproportionaler Unterhalt, Schwefel nur live, Verrat selbst.

### Handel
Vier Formen, je anderes Risikoprofil:
1. **Face-to-Face** – beide live, sofort.
2. **Handelstisch** – eigener Shop im Claim, NPC verkauft nach Regel. Shop ist auch Ziel.
3. **Depot** – Ware wird an einem Marktort hinterlegt, Käufer kauft vor Ort, Bezahlung wartet im Depot. Risiko: der Rückweg mit dem Erlös.
4. **Marktbrett** – Information + Aufträge/Auktionen. **Lieferung immer physisch** per NPC-Aktion ("bring X zu [Ort]") → Karawanen, Eskorten, Überfälle. Kein Teleport, Geografie bleibt wertvoll.

Marktorte (Kartenfeatures, keine NPC-Händler; Unterschied nur über Regeln):
- **Neutraler Markt** (3–5 pro Karte): kampffrei, Raidwaren (Sprengsätze, Gifte, Munition) nicht handelbar, hohe Depotgebühr (Senke). Einziger Ort, an dem ein Offline-NPC garantiert sicher ist.
- **Räuber-Outpost**: kein Kampfverbot, alles handelbar, niedrige Gebühr. Schwefelware zwingt dorthin.
- **Gildenmarkt** (Claim-Upgrade): Regeln, Zoll und Sicherheit setzt die Gilde. Reputation ohne Reputationssystem.

### Kommunikation & Sichtbarkeit
- Nah-Chat, Gildenchat, globaler Chat, Briefe und Schilder in der Welt. Global ohne Positionsdaten aus dem Spiel (keine Koordinaten, kein Kartenteilen). Schilder sind die einzige Kommunikation eines Offline-Charakters.
- Andere Spieler: nur Aussehen/Kosmetik sichtbar; Name + Gilde erst in unmittelbarer Nähe (Rust). Gilden-Wappen als optionale Kosmetik – tragen oder nicht ist Strategie.
- Chronik nennt Angreifer nur, wenn sie nah genug für den Namen kamen, sonst "Unbekannter mit Kupferspeer".

### PvE
- Gefahrenzonen: Zentrum wertvoll/tödlich, Rand sicher/arm. Ereignisse (Karawanen, Bossspawns).

### Sessions
- Kurz (15 Min): NPC konfigurieren, Chronik lesen, Erträge einsammeln. Lang: Raids, Erkundung, Aufbau.

## 4. Tendenz [T]
- Server: Godot headless (ein Code für Client und Simulation), Persistenz in SQLite/Postgres. Entscheidung nach Prototyp; bei 50 Spielern messen.
- Geschäftsmodell: Empfehlung kleiner Einmalkauf (10–20 €) als Cheater-/Alt-Account-Schutz + Kosmetik-Shop (account-gebunden, überlebt Tod). Linus' Wunsch: F2P + Kosmetik. Risiko bei F2P: wirkungslose Bans, Spionage-Alts, Serverkosten ohne Einnahme, Zerg-Sog. Falls F2P: Hürde für Gilden/Claims (Spielstunden oder Verifikation).

## 5. Offen [O]
- Setting: Richtung entschieden (2026-09-07): angelehnt an Rust und Dark and Darker, zunächst nur Menschen. Vorschlag [T]: **bodenständiges Low-Fantasy-Mittelalter ohne Magie** in einer verlassenen Grenzmark nach dem Zerfall eines Königreichs – erklärt, warum es keine Händler-NPCs gibt (alle Waren von Spielern), Ruinen als Bauplätze, Wölfe als Bedrohung, Marktorte als Reste alter Handelsposten. Später mögliche Nicht-Menschen passen als "was aus der Mark zurückkam". Arbeitstitel-Vorschläge: **Vigil** (dein Charakter hält Wache, während du weg bist – trifft den Twist), Hinterland, Grenzmark. Empfehlung: Vigil.
- Konkrete Zahlen: Unterhalt, TTK, Verfallsraten, Solo-Claim-Grenze → Prototyp.
- Ereignis-Design (Karawanen, Bosse).
- Welche Rollen-Presets genau und mit welchen Regeln. → Phase-0-Vorschlag [T] siehe Abschnitt 8, `data/roles.json`.
- Aggressions-Freischaltung: genaue Bedingung.
- Kosmetik-Umfang.
- Name: siehe Setting-Vorschlag (Vigil / Hinterland / Grenzmark).

## 6. Marktrecherche (Stand 2026-09-07)
- **Exakte Kombination nirgends veröffentlicht** (Echtzeit-Live + regelgesteuerter Offline-Avatar + persistente Full-Loot-PvP-Welt). Negativbeweis mit hoher, nicht absoluter Sicherheit.
- **Chronicles of Elyria** (Kickstarter 2016, ~8 Mio. $): "Offline Player Characters" mit skriptbaren Behaviors – nahezu identisches Konzept, C#/JScript-Skripting statt Rollen. Studio 2020 geschlossen, OPC nie spielbar gezeigt. Scheitern war finanziell/organisatorisch (Scope), kein bewiesenes Design-Scheitern.
- **Age of Wushu** (2012/2013, läuft noch): Offline-Charakter bleibt als angreifbarer NPC mit Preset-Beruf (Wache, Händler, Straßenkünstler), Kidnapping-System. Beweist Akzeptanz des Prinzips seit 13 Jahren. Fehlt: editierbare Regeln, Survival/Raiding, Full-Loot.
- **Rust / Mortal Online 2 / Project-Zomboid-Mods:** Körper bleibt, aber passiv. MO2-Community empfindet wehrlosen Offline-Tod als unfair → stärkstes Argument für unsere Regel-Gegenwehr.
- **Screeps:** spielerprogrammierte 24/7-Einheiten skalieren (CPU-Budget pro Spieler), aber Skripting bleibt Nische → Rollen-Ebene ist Pflicht.
- **SEED** (Klang, EA seit Juli 2026): persistente autonome Avatare als Life-Sim. Zeitgeist-Beleg, kein Konkurrent.
- **2D-Top-down-Rust-Konkurrenz:** CryoFall (etabliert, Entwicklung eingestellt), Ruins To Fortress (F2P, EA seit 12/2024). Keiner mit Offline-Twist.
- **Patente:** US 2014/0342808 ("PCs as NPCs") und US 2012/0190443 ("Automatic Movement of Disconnected Character"). Status prüfen (Freedom-to-Operate) vor Early Access.

## 7. Risiken
- Scope. Nur Abschnitt 2 wird zuerst gebaut.
- Regelwerk zu stark → Live überflüssig. Zu schwach → Rust-Schlafsack mit Extraschritten.
- Geschlossene Wirtschaft ohne Wipe: Inflation, Senken, festgefahrene Macht. EVE als Referenz.
- Zerg trotz Bremsen.
- Serverkosten 24/7-Simulation ohne Kaufpreis.
- Godot-Skalierung auf 200–300 Spieler unbelegt.
- Patentlage ungeprüft.
- Regel-Exploits (unbesiegbare Defensiv-Loops) – im Prototyp gezielt suchen.

## 8. Nächster Schritt
**Phase 0 – Rechteck-Prototyp** (Godot 4.7.x, GDScript, Single-Player, kein Netzwerk, keine Grafik):
- Karte aus Datei, 2 Rohstoffe (Holz, Beeren), Bewegung, Twin-Stick-Schuss mit Richtungstreffer, Inventar, Hunger als Unterhalt.
- Ausloggen-Menü: 4 Rollen-Presets (Verstecken, Wache, Sammler, Händler-Platzhalter), aufklappbar zu Regeln; 5 Bedingungen / 6 Aktionen; Marker + Leine mit sichtbarem Radius.
- NPC-Regelmaschine, Chronik.
- Zeitsprung-Knopf: simuliert 8 h Offline in Sekunden, danach spielt man gegen den eigenen Charakter von "gestern".
- Datengetrieben ab Tag 1: Regeln, Rollen, Rohstoffe, Karte als Datendateien. Simulation strikt getrennt von Darstellung (später headless wiederverwendbar).

**Abnahmetest:** Regeln festlegen → Zeitsprung → Charakter finden → Chronik lesen → sofort Regeln ändern wollen. Kommt das Gefühl nicht, ist der Kern nicht da.

**Phase-0-Entscheidungen (2026-09-07, beim Bau des Prototyps getroffen; alle [T], im Spiel per Datendatei änderbar):**
- **Rollen-Presets** (zu [O] "Welche Rollen-Presets genau"): Vorschlag in `data/roles.json`. Verstecken: hungrig → iss · angegriffen → kämpfe zurück · sonst → verstecken. Wache: Leben < 30 % → fliehe zu Hier (2) · angegriffen → kämpfe zurück · hungrig → iss · sonst → bleib bei Hier (4). Sammler: Leben < 40 % → fliehe zu Hier (2) · angegriffen → kämpfe zurück · hungrig → iss · Inventar voll → bleib bei Hier (2) · sonst → sammle Beeren um Hier (8). (Ursprünglich "angegriffen → fliehe zu Hier"; der Balancing-Bericht zeigte 4 von 5 Toden in 8 h, weil Wölfe schneller sind als Menschen – Flucht taugt nur in Deckung, nicht gegen Tiere.) Händler: Platzhalter, verhält sich wie vorsichtige Wache.
- **Leine konkret:** Die Leine ist der Kreis der zuletzt gefeuerten Ortsregel (fliehe zu / bleib bei / sammle um). Aktionen ohne Ort (iss, kämpfe zurück, verstecken) behalten die aktuelle Leine. Beim Ausloggen gilt Hier + Standardradius (balance: npc.default_leash_radius), bis die erste Ortsregel feuert. Zurückkämpfen verfolgt nie über die Leine hinaus.
- **Nicht ausführbare Regel fällt durch:** Trifft eine Regel zu, ist aber nicht ausführbar (iss ohne Essbares, sammle ohne Quelle mit Vorrat in der Leine, sammle bei vollem Inventar), gilt die nächste zutreffende Regel. Das Überspringen steht mit Grund in der Chronik ("nicht möglich: nichts Essbares, übersprungen"), derselbe Grund frühestens nach 30 Minuten erneut (balance: npc.skip_relog_minutes). Grund: sonst friert ein hungriger NPC ohne Beeren ein.
- **"Fremder in Nähe"** zählt auch Tiere (Wölfe). "Inventar voll/leer" ist eine Bedingung mit Parameter (voll | leer).
- **Verstecken:** wirkt nach 3 s ohne Bewegung und ohne Schaden; entdeckt wird, wer näher als 1 Kachel kommt; nach Entdeckung oder Schaden 10 s nicht erneut versteckbar. Schießen oder Laufen beendet das Verstecken.
- **NPC-Kampf:** zielt auf die aktuelle Position (kein Vorhalten), dreht sich zum nächsten sichtbaren Fremden (bis 10 Kacheln), hält beim Zurückkämpfen den Abstand npc.preferred_combat_range, schießt nur mit freier Sichtlinie. Beim Fliehen blickt er in Laufrichtung und zeigt den Rücken.
- **Richtungstreffer Zahlen (Start):** vorn 120°-Bogen ×1, hinten 90°-Bogen ×2 mit halber Rüstung ignoriert, dazwischen seitlich ×1,5; flacher Abzug, Mindestschaden 1.
- **Tod im Prototyp:** Leiche bleibt mit Inventar liegen und ist plünderbar (E); R erzeugt einen frischen Charakter am Spawn.
- **Zeitsprung = Simulationsstufen:** 1 Tick/s, solange kein Spielercharakter einen sichtbaren Fremden in 10 Kacheln hat, kürzlich Schaden nahm oder Projektile fliegen; sonst voller Tick (20 Hz). 8 h laufen in 1–6 s.
- **Simulationsstufen pro Charakter (Server-Vorbereitung):** Charaktere ohne Online-Spieler (oder Zuschauer-Kamera) in 12 Kacheln (balance: offline.lod_radius) rechnen nur einmal pro Sekunde mit entsprechend großem Schritt; alle anderen jeden Tick. Nachbarschaftsabfragen laufen über ein Raster (4 Kacheln). Benchmark headless auf dem Entwicklungsrechner (tools/server_bench.gd, 40×30-Karte, 5 Online-Spieler): 300 NPCs 35 ms/Tick vorher, 15 ms nachher (Budget 50 ms); 1000 NPCs 177 ms (zu langsam). Kosten ≈ 0,17 ms pro fein simuliertem Charakterschritt, grobe Schritte ≈ 1/20 davon. Auf der kleinen Karte laufen fast alle NPCs fein, weil 5 Spieler mit 12 Kacheln Radius die Karte abdecken; auf einer großen Karte trägt die grobe Stufe. Fazit für Godot headless: ~300 feine Charaktere pro Serverprozess bei 20 Hz, mehr nur mit Stufen oder Optimierung (GDScript, Einzelkern).
- **Freischalten von Regel-Bausteinen umgesetzt** (Design [E]): Bausteine tragen in conditions.json/actions.json ein optionales `unlock` {fact, label}; Freischaltungen hängen am Besitzer (todesfest, im Spielstand und auf dem Server). Erster Baustein: **"greife an (Radius)"**, frei nachdem der Spieler selbst einmal von einem fremden Offline-Charakter getroffen wurde (zu [O] "Aggressions-Freischaltung: genaue Bedingung" – Vorschlag [T]). Gesperrte Bausteine erscheinen im Editor ausgegraut mit Hinweis; ein NPC führt gesperrte Regeln nicht aus ("Baustein nicht freigeschaltet").
- **Logout-Übergang umgesetzt:** 45 s nach dem Ausloggen (balance: logout.transition_seconds), bei Schaden in den letzten 60 s (logout.combat_window) erst 60 s nach dem letzten Treffer. Während des Übergangs ist "verstecken" nicht ausführbar (fällt durch), der Charakter bleibt sichtbar und verwundbar; die Chronik vermerkt Grund und Ende.
- **Ausrüstung in Phase 0 (`data/items.json`):** Schleuder (Start, Fernkampf 10), Keule (Nahkampf 16, 3 Holz), Holzpanzer (Rüstung 3, 6 Holz). Werkbank per Taste C, Q wechselt die Waffe. Kein Verschleiß, kein Verlust außer beim Tod (Leiche ist plünderbar, auch Ausrüstung). Der NPC nutzt beim Zurückkämpfen die Keule nur, wenn der Feind schon in Reichweite steht, sonst die Schleuder auf Abstand.
- **Marker:** live setzen (M), im Ausloggen-Menü umbenennen und löschen; Regeln mit gelöschtem Marker fallen auf "Hier" zurück. Kennungen werden nicht wiederverwendet.
- **Chronik mit Ort:** jeder Eintrag trägt die Position; auf der Karte erscheinen die Einträge als nummerierte Spur, solange die Chronik offen ist.
- **Spielstand:** wird automatisch geschrieben (Ausloggen, Zeitsprung, Einloggen, Versus, Beenden) und beim Start geladen; "Neues Spiel" löscht ihn. Format binär (exakter Verlauf), Inhalt ist dasselbe Dictionary, das später als Netzwerk-Snapshot dient.
- **Nicht umgesetzt in Phase 0:** Claims/Marktorte; Hunger-Zustandseffekt beschränkt auf halbe Geschwindigkeit; Waffen-Verschleiß.

**Phase 1 – Inhalt (ab 2026-09-07, Reihenfolge festgelegt: Bauen → Claims → Handelstisch → weitere Rohstoffe/Ketten → Sensoren/Turrets):**
- **Bauen (umgesetzt):** `data/buildings.json` mit Holzwand (4 Holz, 40 LP, blockiert alle) und Holztür (6 Holz, 30 LP, nur der Besitzer und seine NPCs gehen durch). Halbkachelraster, drehbar (T), Reichweite 3 Kacheln, nur live (NPCs bauen nie). Projektile bleiben an Bauteilen hängen, ohne sie zu beschädigen; Holz wird nur mit Nahkampf (Keule) eingeschlagen, und nur von Live-Spielern – NPCs und Wölfe brechen nie Wände (nur Live kann Nehmen und Verändern). Holz verfällt 1 LP je Stunde (balance: buildings.json decay_per_hour), eigener Abriss gibt 50 % zurück. Wegsuche und Leine berücksichtigen Bauteile; ein NPC außerhalb seiner Leine folgt der Wegsuche, statt stur zur Mitte zu laufen.
- **Claims (umgesetzt, Zahlen [T] in balance.json `claim`):** Claim-Anker (10 Holz, 60 LP, nur live, einer je Solo-Spieler, mindestens 8 Kacheln von fremden Ankern). Kacheln werden einzeln beansprucht (Baumodus, Taste 3, 1 Holz), müssen 4-nachbarschaftlich an den Claim angrenzen; Obergrenze solo 40. Unterhalt je Stunde = 0,05 × n × (1 + n/10) Holz (10 Kacheln 1/h, 40 Kacheln 10/h), abgeliefert per E neben dem eigenen Anker (Vorrat max 200). Leerer Vorrat: alle 6 h verliert der Claim die ankerfernste Kachel, bis nur die Ankerkachel bleibt. Anker zerstört oder verfallen: 2 h Schonfrist, in der der Besitzer auf seinem Land neu verankern darf, danach ist das Land frei. Rechte: nur der Eigentümer baut; Bauteile auf fremdem Claim verfallen dreifach schnell; Offline-NPCs sammeln nie auf fremdem Land, Fremde live schon (Ereignis "Diebstahl"); wer in fremdem Claim ausloggt, wird an die Grenze geschoben. Neue Bedingung "Fremder im eigenen Claim", frei ab dem ersten Anker (Freischaltung "owned_anchor"). Noch nicht: Korridor-Verbot (nur Angrenzung), Spawn-Anker, Gilden-Anker, Zoll.
- **Handelstisch (umgesetzt):** Bauteil (8 Holz, 30 LP, 2×1 Halbzellen). Der Besitzer lagert per E daneben Waren ein (max 60) und setzt bis zu 3 Angebote "verkaufe X für Y" (Tausch, keine Währung – Design: geschlossene Spielerwirtschaft). Fremde kaufen live per E; die Bezahlung landet im Tisch, der Besitzer holt sie beim nächsten Einloggen. Der Tisch arbeitet offline von selbst (kein NPC nötig). "Shop ist auch Ziel": wird er eingeschlagen, fällt der Inhalt dem Zerstörer zu. Online läuft alles über den Server; die Tafel folgt Snapshots. Noch nicht: Depot, Marktbrett, Lieferung per NPC ("bring X zu [Ort]"), Zoll.

**Netzwerk-Spike (2026-09-07, Ergebnis; alle Zahlen vom Entwicklungsrechner, Loopback):**
- Aufbau: `server/server_main.gd` (Godot headless, dieselbe Sim, autoritativ, 20 Hz, ENet), `game/net_client.gd` (Spiegelwelt aus Snapshots, dieselbe Darstellung), `tools/bot_clients.gd` (N Clients in einem Prozess). Trennen = Charakter wird NPC mit seinen Regeln, Übergang läuft; Wiederkommen unter demselben Namen = Einloggen in den eigenen NPC. Das Spiel selbst verbindet mit `godot --path . -- --connect host:port --name X`.
- Server mit 200 NPC-Füllung + 50 Bots (laufen, schießen, loggen aus und wieder ein): Tick Ø 5–12 ms, max 37 ms (Budget 50 ms). Godot headless trägt die Zielgröße (200–300 Charaktere) auf einem Prozess.
- Bandbreite: erstes Format (Dictionaries, eigene Chronik in jedem Snapshot) 24 MB/s raus für 50 Clients. Kompaktes Format (Zeile je Charakter als Array, Stammdaten einmal, eigene Details und Quellen nur bei Änderung) 4,5 MB/s, ≈ 56 Byte je Charakter und Snapshot bei 10 Hz. Auf der kleinen Karte sind ≈ 160 Charaktere in jedem Sichtbereich (22 Kacheln); auf einer großen Karte entsprechend weniger. Nächste Hebel, falls nötig: Delta-Positionen, 5 Hz für ferne Charaktere, kleinerer Sichtbereich.
- Große Karte (Generator `sim/map_gen.gd`, 120×90, Seed 7, 25 Spieler-Spawns am Rand, Wölfe innen), 300 NPCs + 50 Bots: Tick Ø 9–12 ms, max 35 ms; Bandbreite 1,2 MB/s gesamt (≈ 25 KB/s je Client, ≈ 38 Charaktere je Snapshot). Die Karte geht mit der Beitrittsnachricht an den Client (11 KB), Clients brauchen keine passende Kartendatei.
- **Design-Befund Vergeltungskette:** 50 zufällig schießende Bots ließen die NPC-Zahl in 100 s von 198 auf 98 fallen. Ein verirrter Treffer macht den Getroffenen "angegriffen", er kämpft gegen den Schützen zurück, dessen Treffer treffen Umstehende, die ebenfalls zurückkämpfen. "Kämpfe zurück" ist wörtlich richtig, aber Querschläger zünden Ketten. Entschieden [E] (2026-09-07): Querschläger sind legitime Treffer; wer trifft, hat angegriffen. Vergeltungsketten sind Teil des Spiels und ein Grund, nicht in Menschenmengen zu schießen.
- **Bewertung Godot headless (Tendenz [T] bestätigt):** ein Code für Client und Simulation funktioniert, Spielstand = Snapshot-Format, Tickzeit im Budget. Persistenz: Server speichert alle 60 s (`user://server_save.dat`); SQLite/Postgres bleibt offen.

Danach: Netzwerk-Spike (Godot headless, 300 NPCs, Tickzeit messen; 50 Bot-Clients per ENet) → erst dann Setting, Name, Optik.

## 9. Verworfen
- "Rust in 2D" als reine Kopie. · 4X-/Königreichs-Verwaltungsmodus. · Gilden-Quests als Sammelliste. · Single-Shard-MMO. · Bullet-Hell, Auto-Angriff. · Charakter-Level/Stats. · Regelmäßige Wipes als Design. · Hunger/Kälte als Minispiel. · Trefferzonen (Richtungstreffer stattdessen). · Regel-Bausteine als Loot. · Community-Server. · Node/TS-Server mit duplizierter Logik (vorbehaltlich Prototyp). · Markt mit Teleport. · "Nächstes X" ohne Leine. · NPC-Händler mit Sonderware. · "Greife an" im Startvokabular.
