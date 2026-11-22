import Foundation
import PriceCore

// Benchmark: loads feeds (from a directory of `<store>.json` files or the app cache),
// builds the catalog and measures per-keystroke search latency.
//
//   swift run -c release pricebench [feed-directory]

@main
struct PriceBench {
    static func main() async throws {
        let clock = ContinuousClock()
        var feeds: [Store: Data] = [:]
        if CommandLine.arguments.count > 1 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[1])
            for store in Store.allCases {
                if let data = try? Data(contentsOf: dir.appendingPathComponent("\(store.feedKey).json"), options: .alwaysMapped) {
                    feeds[store] = data
                }
            }
        } else {
            let sync = DataSyncService()
            if await !sync.hasCache {
                print("Kein Cache – lade Feeds …")
                let report = await sync.sync()
                print("geladen: \(report.changed.count) Feeds, \(report.bytesDownloaded / 1_000_000) MB")
            }
            feeds = await sync.cachedFeeds()
        }
        let bytes = feeds.values.reduce(0) { $0 + $1.count }
        print("Feeds: \(feeds.count), \(bytes / 1_000_000) MB JSON")

        let catalog = try await Catalog.build(feeds: feeds)
        print("Katalog: \(catalog.count) Produkte, \(catalog.history.count) Preispunkte, Index \(catalog.index.byteCount / 1_000_000) MB, gebaut in \(catalog.buildDuration)")

        let engine = SearchEngine(catalog: catalog)
        let warm = clock.measure { engine.warmUp(SortKey.allCases) }
        print("Sortier-Permutationen (alle Schlüssel): \(warm)")

        func bench(_ label: String, _ request: SearchRequest, runs: Int = 20) {
            var best = Duration.seconds(100)
            var total = Duration.zero
            var count = 0
            for _ in 0..<runs {
                engine.resetTextCache() // no incremental reuse → worst case
                let d = clock.measure { count = engine.run(request)!.ids.count }
                best = min(best, d)
                total += d
            }
            let ms = { (d: Duration) in String(format: "%.2f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            print("  \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(String(count).padding(toLength: 7, withPad: " ", startingAt: 0)) Treffer  best \(ms(best))  avg \(ms(total / runs))")
        }

        let today = DayMath.today
        var filters = FilterState()
        print("Kalte Suchen (kein inkrementeller Cache):")
        bench("<leer>, Grundpreis ↑", SearchRequest(text: "", filters: filters, sort: .default, today: today))
        bench("<leer>, Name ↑", SearchRequest(text: "", filters: filters, sort: ResultOrder(key: .name, ascending: true), today: today))
        for q in ["m", "mi", "milch", "vollmilch 1l", "käse", "kase gouda", "bio ja", "a e", "coca cola -zero", "schokolade 100g"] {
            bench("\"\(q)\"", SearchRequest(text: q, filters: filters, sort: .default, today: today))
        }
        bench("\"milch\" Relevanz", SearchRequest(text: "milch", filters: filters, sort: ResultOrder(key: .relevance, ascending: true), today: today))
        filters.trend = .reduced
        filters.onlyBio = true
        bench("<leer> + reduziert + bio", SearchRequest(text: "", filters: filters, sort: .default, today: today))

        print("Tippen simuliert (inkrementell, gleiche Engine):")
        let typing = SearchEngine(catalog: catalog)
        typing.warmUp()
        var worst = Duration.zero
        let phrase = "bio vollmilch 3.5"
        for n in 1...phrase.count {
            let text = String(phrase.prefix(n))
            let d = clock.measure { _ = typing.run(SearchRequest(text: text, filters: FilterState(), sort: .default, today: today)) }
            worst = max(worst, d)
        }
        print("  \"\(phrase)\" Zeichen für Zeichen – langsamster Tastenanschlag: \(worst)")

        let sample = engine.run(SearchRequest(text: "vollmilch", filters: FilterState(), sort: .default, today: today))!
        for id in sample.ids.prefix(5) {
            let p = catalog[id]
            print("  \(p.store.displayName) | \(p.name) | \(p.quantity) \(p.unit) | \(p.price) € | \(String(format: "%.2f", p.unitPrice)) €/\(p.unit.baseLabel)")
        }
    }
}
