# Heiße Preise für macOS

Nativer, tastaturgesteuerter macOS-Client (Swift 6, SwiftUI + AppKit, macOS 15+, Apple Silicon)
für die österreichische Preisdatenbank [heisse-preise.io](https://heisse-preise.io).
Keine WebViews, keine Fremd-Abhängigkeiten – nur Foundation, SwiftUI, AppKit, Charts.

## Bauen & starten

Funktioniert mit den Command Line Tools allein (kein Xcode nötig):

```bash
./scripts/build-app.sh && open build/HeissePreise.app
```

Benchmark der Such-Engine (lädt bei Bedarf die Feeds in den Cache):

```bash
swift run -c release pricebench
```

## Architektur

| Pfad | Inhalt |
|---|---|
| `Sources/PriceCore/Models` | `Store`, `Product` (flaches Struct, alle abgeleiteten Werte vorberechnet), `PricePoint` (8 Byte), Kategorien |
| `Sources/PriceCore/Engine/FeedParser.swift` | Handgeschriebener JSON-Parser für das komprimierte Feed-Format (`analysis.js#compress`) |
| `Sources/PriceCore/Engine/Catalog.swift` | Paralleles Parsen aller Händler-Feeds → ein Produkt-Array + ein gemeinsamer Preisverlaufs-Puffer |
| `Sources/PriceCore/Engine/SearchIndex.swift` | Alle normalisierten Suchtexte in einem Byte-Puffer; `memmem`-Scan parallel über alle Kerne |
| `Sources/PriceCore/Engine/QueryEngine.swift` | Filter + Facetten-Zähler in einem Durchlauf, vorberechnete Sortier-Permutationen, inkrementelle Suche |
| `Sources/PriceCore/Services/DataSyncService.swift` | Download, SSD-Cache (`~/Library/Caches/io.heisse-preise.mac`), ETag/Last-Modified-Revalidierung |
| `Sources/HeissePreise` | App: `AppModel`, Sidebar, `NSTableView`-Ergebnisliste, Inspector mit Swift-Charts-Preisverlauf |

Daten: `https://heisse-preise.io/data/latest-canonical.<store>.compressed.json` (ein Feed pro Händler, gzip).

Messwerte (M-Serie, 160 730 Produkte, 1,27 Mio. Preispunkte): Katalog-Aufbau aus dem Cache ≈ 0,12 s,
kalte Suche 0,7–4 ms, Tastenanschlag beim Tippen ≤ 3 ms.

## Tastatur

| Taste | Aktion |
|---|---|
| `⌘F` / `⌘K` | Suchfeld fokussieren |
| `↑` `↓` `⇞` `⇟` | Ergebnisliste navigieren (Fokus bleibt im Suchfeld) |
| `↩︎` / `⌘I` | Details öffnen |
| `Esc` | Details schließen → Suche leeren → Filter zurücksetzen |
| `⌘C` | Produktname + Preis kopieren (wenn kein Text markiert ist) |
| `⌘O` / `⇧⌘O` | Im Shop öffnen / im Shop suchen |
| `⌘D` | Produkt merken (Merkliste) |
| `⇧⌘D` | Aktuelle Suche inkl. Filter anpinnen |
| `⌘R` / `⌥⌘R` | Daten aktualisieren / komplett neu laden |
| `⌃⌘1…9` | Sortierung wählen |

Suchsyntax: alle Wörter müssen vorkommen (beliebige Reihenfolge, akzent-/umlautunabhängig), `-wort` schließt aus.

## Hinweise zu den Daten

- Laut Feed werden derzeit nur noch die BILLA-Preise laufend aktualisiert; bei den anderen Händlern
  zeigt die Sidebar das Datum des letzten Feed-Stands, deren Produkte sind als „nicht verfügbar“ markiert
  (abgeblendet; Filter „Nur aktuell verfügbar“). Lidl und PENNY liefern aktuell leere Feeds.
- Aktionen/Reduktionen werden – wie auf heisse-preise.io – über `Preis < vorheriger Preis` erkannt.
  Schrumpflation ist nicht erkennbar, weil der Feed nur die aktuelle Packungsgröße enthält.
