import Foundation

/// Immutable in-memory database: flat product array, one shared price-history buffer
/// and the packed search index. Built once per data refresh, then shared read-only.
public final class Catalog: Sendable {
    public let products: [Product]
    /// All price histories back to back (each product's slice is newest-first).
    public let history: [PricePoint]
    public let index: SearchIndex
    public let feeds: [Store: FeedSummary]
    public let lookup: [ProductKey: Int32]
    public let buildDuration: Duration

    public struct FeedSummary: Sendable, Hashable {
        public var productCount: Int
        /// Newest date in the feed – tells how current the scraper data for this chain is.
        public var latestDay: Day?
    }

    public var count: Int { products.count }
    public var latestDay: Day? { feeds.values.compactMap(\.latestDay).max() }

    public subscript(id: Int32) -> Product { products[Int(id)] }

    public func history(of product: Product) -> ArraySlice<PricePoint> {
        let start = Int(product.historyStart)
        return history[start..<(start + Int(product.historyCount))]
    }

    public static let empty = Catalog(products: [], history: [], strings: [], feeds: [:], buildDuration: .zero)

    init(products: [Product], history: [PricePoint], strings: [[UInt8]], feeds: [Store: FeedSummary], buildDuration: Duration) {
        self.products = products
        self.history = history
        self.index = SearchIndex(strings: strings)
        self.feeds = feeds
        self.buildDuration = buildDuration
        var lookup: [ProductKey: Int32] = [:]
        lookup.reserveCapacity(products.count)
        for p in products { lookup[p.key] = p.id }
        self.lookup = lookup
    }

    // MARK: Building

    /// Parses all raw feeds in parallel and assembles the catalog.
    public static func build(feeds raw: [Store: Data]) async throws -> Catalog {
        let clock = ContinuousClock()
        let start = clock.now
        let parts = try await withThrowingTaskGroup(of: (Store, StorePart).self) { group in
            for (store, data) in raw {
                group.addTask { (store, try StorePart(store: store, feed: FeedParser.parse(data))) }
            }
            var parts: [Store: StorePart] = [:]
            for try await (store, part) in group { parts[store] = part }
            return parts
        }

        // Concatenate in a fixed store order so ids are deterministic.
        var products: [Product] = []
        var history: [PricePoint] = []
        var strings: [[UInt8]] = []
        let total = parts.values.reduce(0) { $0 + $1.items.count }
        products.reserveCapacity(total)
        strings.reserveCapacity(total)
        history.reserveCapacity(parts.values.reduce(0) { $0 + $1.history.count })
        var summaries: [Store: FeedSummary] = [:]

        for store in Store.allCases {
            guard let part = parts[store] else { continue }
            summaries[store] = FeedSummary(productCount: part.items.count, latestDay: part.latestDay)
            let historyBase = Int32(history.count)
            history.append(contentsOf: part.history)
            for item in part.items {
                let id = Int32(products.count)
                let start = Int(item.historyStart)
                products.append(Product(
                    id: id, store: store, storeID: item.storeID, name: item.name, urlPath: item.urlPath,
                    categoryCode: item.categoryCode, unit: item.unit, flags: item.flags, quantity: item.quantity,
                    history: part.history[start..<(start + Int(item.historyCount))],
                    historyStart: historyBase + item.historyStart
                ))
            }
            strings.append(contentsOf: part.searchStrings)
        }
        return Catalog(products: products, history: history, strings: strings, feeds: summaries,
                       buildDuration: clock.now - start)
    }
}

/// Products of one store, normalised but not yet assigned global ids.
struct StorePart: Sendable {
    struct Item: Sendable {
        var storeID: String
        var name: String
        var urlPath: String
        var categoryCode: UInt8
        var unit: ProductUnit
        var flags: Product.Flags
        var quantity: Double
        var historyStart: Int32
        var historyCount: Int32
    }

    var items: [Item] = []
    var history: [PricePoint] = []
    var searchStrings: [[UInt8]] = []
    var latestDay: Day?

    init(store: Store, feed: ParsedFeed) {
        items.reserveCapacity(feed.items.count)
        searchStrings.reserveCapacity(feed.items.count)
        history.reserveCapacity(feed.prices.count)
        let budgetBrands = Store.allBudgetBrands.map { TextNormalizer.normalize($0) }
        latestDay = feed.dates.max()
        var points: [PricePoint] = []

        for raw in feed.items {
            // Feeds are per store, but be defensive about the store index.
            if raw.storeIndex >= 0, raw.storeIndex < feed.stores.count, feed.stores[raw.storeIndex] != store.feedKey { continue }

            points.removeAll(keepingCapacity: true)
            for p in feed.prices[raw.pricesStart..<(raw.pricesStart + raw.pricesCount)] where p.cents > 0 {
                guard p.dateIndex >= 0, Int(p.dateIndex) < feed.dates.count else { continue }
                points.append(PricePoint(day: feed.dates[Int(p.dateIndex)], cents: p.cents))
            }
            guard !points.isEmpty else { continue }
            // Newest first (the feed already is, but don't rely on it).
            if !zip(points, points.dropFirst()).allSatisfy({ $0.day >= $1.day }) {
                points.sort { $0.day > $1.day }
            }

            var name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.contains("M & M") { name = name.replacingOccurrences(of: "M & M", with: "M&M") }
            let normalizedName = TextNormalizer.normalize(name)

            var flags: Product.Flags = []
            if raw.unavailable { flags.insert(.unavailable) }
            if raw.weighted { flags.insert(.weighted) }
            if raw.bio { flags.insert(.bio) }
            if budgetBrands.contains(where: { normalizedName.contains($0) }) { flags.insert(.budget) }

            let unit = ProductUnit(raw: raw.unit)
            var quantity = raw.quantity.isFinite && raw.quantity > 0 ? raw.quantity : 0
            if let rawUnit = raw.unit?.lowercased(), rawUnit == "kg" || rawUnit == "l" || rawUnit == "m" {
                quantity *= rawUnit == "m" ? 100 : 1000
            }

            let start = Int32(history.count)
            history.append(contentsOf: points)
            items.append(Item(
                storeID: raw.id, name: name, urlPath: raw.url,
                categoryCode: ProductCategory.decode(raw.category), unit: unit, flags: flags, quantity: quantity,
                historyStart: start, historyCount: Int32(points.count)
            ))

            // Search text mirrors heisse-preise.io: "<name> <quantity> <unit>".
            var search = normalizedName
            if quantity > 0 {
                search.append(0x20)
                TextNormalizer.append(Formatting.plainNumber(quantity) + (raw.unit ?? ""), to: &search)
            }
            searchStrings.append(search)
        }
    }
}

public enum Formatting {
    /// `400`, `1.5` – no grouping, no trailing zeros.
    public static func plainNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
