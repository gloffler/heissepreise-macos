import Foundation
import Synchronization

// MARK: - Filter & sort model

public enum PriceTrend: String, CaseIterable, Codable, Sendable, Identifiable {
    case any, reduced, increased, allTimeLow
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: "Alle"
        case .reduced: "Reduziert"
        case .increased: "Teurer"
        case .allTimeLow: "Tiefstpreis"
        }
    }
}

public struct FilterState: Codable, Hashable, Sendable {
    public var stores: Set<Store> = Set(Store.allCases)
    public var trend: PriceTrend = .any
    public var onlyBudget = false
    public var onlyBio = false
    public var hideUnavailable = false
    /// Only products whose price changed within the last N days.
    public var changedWithinDays: Int?
    public var minPrice: Double?
    public var maxPrice: Double?
    public var minUnitPrice: Double?
    public var maxUnitPrice: Double?
    public var unitFilter: UnitFilter = .any
    /// In base units (kg, L, Stk).
    public var minQuantity: Double?
    public var maxQuantity: Double?
    /// Packed sub-category codes; empty = all categories.
    public var categories: Set<UInt8> = []

    public init() {}

    public static let `default` = FilterState()

    public var activeCount: Int {
        var n = 0
        if stores.count != Store.allCases.count { n += 1 }
        if trend != .any { n += 1 }
        if onlyBudget { n += 1 }
        if onlyBio { n += 1 }
        if hideUnavailable { n += 1 }
        if changedWithinDays != nil { n += 1 }
        if minPrice != nil || maxPrice != nil { n += 1 }
        if minUnitPrice != nil || maxUnitPrice != nil { n += 1 }
        if unitFilter != .any || minQuantity != nil || maxQuantity != nil { n += 1 }
        if !categories.isEmpty { n += 1 }
        return n
    }
}

public enum SortKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case relevance, store, name, quantity, unitPrice, price, change, changePercent, lastChange
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .relevance: "Relevanz"
        case .store: "Händler"
        case .name: "Name"
        case .quantity: "Menge"
        case .unitPrice: "Grundpreis"
        case .price: "Preis"
        case .change: "Änderung (€)"
        case .changePercent: "Änderung (%)"
        case .lastChange: "Letzte Änderung"
        }
    }
}

public struct ResultOrder: Codable, Hashable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
    /// Relevance: best text matches first; without a query the most recent price changes first.
    public static let `default` = ResultOrder(key: .relevance, ascending: true)
}

public struct SearchRequest: Hashable, Sendable {
    public var text: String
    public var filters: FilterState
    public var sort: ResultOrder
    public var today: Day
    /// Restrict results to these product ids (e.g. the watchlist); `nil` = whole catalog.
    public var restrictTo: Set<Int32>?
    public init(text: String, filters: FilterState, sort: ResultOrder, today: Day = DayMath.today, restrictTo: Set<Int32>? = nil) {
        self.text = text
        self.filters = filters
        self.sort = sort
        self.today = today
        self.restrictTo = restrictTo
    }
}

public struct SearchResult: Sendable {
    public var ids: [Int32]
    /// Matches per store ignoring the store filter (facet counts), indexed by `Store.rawValue`.
    public var storeCounts: [Int]
    /// Matches per main category ignoring the category filter, indexed by main category index.
    public var mainCategoryCounts: [Int]
    /// Matches per packed sub-category code ignoring the category filter.
    public var subCategoryCounts: [Int]
    public var textMatches: Int
    public var duration: Duration
    public var request: SearchRequest

    public static func empty(_ request: SearchRequest) -> SearchResult {
        SearchResult(ids: [], storeCounts: Array(repeating: 0, count: Store.allCases.count),
                     mainCategoryCounts: Array(repeating: 0, count: ProductCategory.all.count),
                     subCategoryCounts: Array(repeating: 0, count: 256), textMatches: 0, duration: .zero, request: request)
    }
}

// MARK: - Engine

/// Executes searches against an immutable catalog. Thread-safe; meant to run off the main actor.
public final class SearchEngine: Sendable {
    public let catalog: Catalog

    private struct TextCache {
        var query: SearchQuery
        var ids: [Int32]
    }

    private let textCache = Mutex<TextCache?>(nil)
    /// Lazily built, cached global sort permutations (ascending, "missing" values last).
    private let permutations = Mutex<[SortKey: Permutation]>([:])

    private struct Permutation: Sendable {
        var order: [Int32]
        /// Items at and after this index have no value for the key (e.g. no unit price).
        var missingStart: Int
    }

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    /// Forgets the incremental text cache (benchmarks, catalog swaps).
    public func resetTextCache() {
        textCache.withLock { $0 = nil }
    }

    /// Pre-builds the permutation for the default sort so the first query is instant.
    public func warmUp(_ keys: [SortKey] = [.unitPrice]) {
        for key in keys { _ = permutation(for: key) }
    }

    public func run(_ request: SearchRequest, isCancelled: () -> Bool = { false }) -> SearchResult? {
        let clock = ContinuousClock()
        let start = clock.now
        let products = catalog.products
        guard !products.isEmpty else { return .empty(request) }

        // 1. Text search (incremental when the query only narrows the previous one).
        let query = SearchQuery(request.text)
        var textIDs: [Int32]?
        if query.isEmpty {
            textIDs = nil
        } else {
            let cached = textCache.withLock { $0 }
            if let cached, cached.query == query {
                textIDs = cached.ids
            } else if let cached, query.refines(cached.query) {
                textIDs = catalog.index.search(query, within: cached.ids)
            } else {
                textIDs = catalog.index.search(query, within: nil)
            }
            textCache.withLock { $0 = TextCache(query: query, ids: textIDs!) }
        }
        if let restrict = request.restrictTo {
            textIDs = textIDs.map { $0.filter { restrict.contains($0) } } ?? restrict.sorted()
        }
        if isCancelled() { return nil }

        // 2. Filters + facet counts in a single pass.
        let f = request.filters
        var storeMask: UInt32 = 0
        for s in f.stores { storeMask |= 1 << UInt32(s.rawValue) }
        var categoryMask = [Bool](repeating: f.categories.isEmpty, count: 256)
        for c in f.categories { categoryMask[Int(c)] = true }
        let minCents = f.minPrice.map { Int32(($0 * 100).rounded(.down)) } ?? Int32.min
        let maxCents = f.maxPrice.map { Int32(($0 * 100).rounded(.up)) } ?? Int32.max
        let minUnit = f.minUnitPrice ?? -.infinity
        let maxUnit = f.maxUnitPrice ?? .infinity
        let hasUnitRange = f.minUnitPrice != nil || f.maxUnitPrice != nil
        let minQty = f.minQuantity ?? -.infinity
        let maxQty = f.maxQuantity ?? .infinity
        let hasQtyRange = f.minQuantity != nil || f.maxQuantity != nil
        let changedSince: Day? = f.changedWithinDays.map { request.today - Day($0) }

        var storeCounts = [Int](repeating: 0, count: Store.allCases.count)
        var subCounts = [Int](repeating: 0, count: 256)
        var ids: [Int32] = []
        ids.reserveCapacity(textIDs?.count ?? products.count)

        products.withUnsafeBufferPointer { buffer in
            @inline(__always) func visit(_ id: Int32) {
                let p = buffer[Int(id)]
                if f.hideUnavailable && p.isUnavailable { return }
                if f.onlyBio && !p.isBio { return }
                if f.onlyBudget && !p.isBudget { return }
                switch f.trend {
                case .any: break
                case .reduced: if !p.isReduced { return }
                case .increased: if !p.isIncreased { return }
                case .allTimeLow: if !p.isAllTimeLow { return }
                }
                if let changedSince, p.lastChange < changedSince || p.historyCount < 2 { return }
                if p.cents < minCents || p.cents > maxCents { return }
                if hasUnitRange && !(p.unitPrice >= minUnit && p.unitPrice <= maxUnit) { return }
                if f.unitFilter != .any && p.unit.unitFilter != f.unitFilter { return }
                if hasQtyRange {
                    let q = p.baseQuantity
                    if !(q > 0 && q >= minQty && q <= maxQty) { return }
                }
                let storeOK = storeMask & (1 << UInt32(p.store.rawValue)) != 0
                let categoryOK = categoryMask[Int(p.categoryCode)]
                if categoryOK { storeCounts[Int(p.store.rawValue)] += 1 }
                if storeOK {
                    subCounts[Int(p.categoryCode)] += 1
                    if categoryOK { ids.append(id) }
                }
            }
            if let textIDs {
                for id in textIDs { visit(id) }
            } else {
                for id in 0..<Int32(buffer.count) { visit(id) }
            }
        }
        if isCancelled() { return nil }

        var mainCounts = [Int](repeating: 0, count: ProductCategory.all.count)
        for (code, n) in subCounts.enumerated() where n > 0 {
            mainCounts[min(ProductCategory.main(of: UInt8(code)), mainCounts.count - 1)] += n
        }

        // 3. Sort.
        ids = sort(ids, by: request.sort, query: query)

        return SearchResult(ids: ids, storeCounts: storeCounts, mainCategoryCounts: mainCounts,
                            subCategoryCounts: subCounts, textMatches: textIDs?.count ?? products.count,
                            duration: clock.now - start, request: request)
    }

    // MARK: Sorting

    private func sort(_ ids: [Int32], by order: ResultOrder, query: SearchQuery) -> [Int32] {
        guard ids.count > 1 else { return ids }
        if order.key == .relevance {
            guard !query.positive.isEmpty else {
                return sort(ids, by: ResultOrder(key: .lastChange, ascending: !order.ascending), query: query)
            }
            guard ids.count <= 40_000 else {
                return sort(ids, by: ResultOrder(key: .unitPrice, ascending: order.ascending), query: query)
            }
            let index = catalog.index
            let unitRank = rank(for: .unitPrice)
            var scored = ids.map { (id: $0, score: index.relevance(of: $0, query: query)) }
            scored.sort { a, b in
                if a.score != b.score { return order.ascending ? a.score > b.score : a.score < b.score }
                return unitRank[Int(a.id)] < unitRank[Int(b.id)]
            }
            return scored.map(\.id)
        }

        let perm = permutation(for: order.key)
        // Large result sets: walk the precomputed global order, O(N) instead of O(n log n).
        if ids.count > 4_096 {
            var member = [Bool](repeating: false, count: catalog.count)
            for id in ids { member[Int(id)] = true }
            var out: [Int32] = []
            out.reserveCapacity(ids.count)
            if order.ascending {
                for id in perm.order where member[Int(id)] { out.append(id) }
            } else {
                for id in perm.order[..<perm.missingStart].reversed() where member[Int(id)] { out.append(id) }
                for id in perm.order[perm.missingStart...] where member[Int(id)] { out.append(id) }
            }
            return out
        }
        // Small result sets: sort by global rank.
        let ranks = rank(for: order.key)
        let missingStart = Int32(perm.missingStart)
        return ids.sorted { a, b in
            let ra = ranks[Int(a)], rb = ranks[Int(b)]
            if order.ascending { return ra < rb }
            let ma = ra >= missingStart, mb = rb >= missingStart
            if ma != mb { return mb }
            return ma ? ra < rb : ra > rb
        }
    }

    private let ranks = Mutex<[SortKey: [Int32]]>([:])

    private func rank(for key: SortKey) -> [Int32] {
        if let cached = ranks.withLock({ $0[key] }) { return cached }
        let perm = permutation(for: key)
        var rank = [Int32](repeating: 0, count: catalog.count)
        for (position, id) in perm.order.enumerated() { rank[Int(id)] = Int32(position) }
        ranks.withLock { $0[key] = rank }
        return rank
    }

    private func permutation(for key: SortKey) -> Permutation {
        if let cached = permutations.withLock({ $0[key] }) { return cached }
        let products = catalog.products
        let index = catalog.index
        var order = (0..<Int32(products.count)).map { $0 }
        var storeRank = [Int](repeating: 0, count: Store.allCases.count)
        for (rank, store) in Store.allCases.sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }).enumerated() {
            storeRank[Int(store.rawValue)] = rank
        }

        func isMissing(_ p: Product) -> Bool {
            switch key {
            case .unitPrice: !p.hasUnitPrice
            case .quantity: p.quantity <= 0
            case .change, .changePercent: p.historyCount < 2
            default: false
            }
        }

        products.withUnsafeBufferPointer { ps in
            order.sort { a, b in
                let pa = ps[Int(a)], pb = ps[Int(b)]
                let ma = isMissing(pa), mb = isMissing(pb)
                if ma != mb { return mb }
                switch key {
                case .relevance, .unitPrice:
                    if pa.unitPrice != pb.unitPrice { return pa.unitPrice < pb.unitPrice }
                case .store:
                    if pa.store != pb.store { return storeRank[Int(pa.store.rawValue)] < storeRank[Int(pb.store.rawValue)] }
                case .name:
                    let c = index.compare(a, b)
                    if c != 0 { return c < 0 }
                case .quantity:
                    if pa.unit.unitFilter != pb.unit.unitFilter { return pa.unit.unitFilter.rawValue < pb.unit.unitFilter.rawValue }
                    if pa.baseQuantity != pb.baseQuantity { return pa.baseQuantity < pb.baseQuantity }
                case .price:
                    if pa.cents != pb.cents { return pa.cents < pb.cents }
                case .change:
                    if pa.changeCents != pb.changeCents { return pa.changeCents < pb.changeCents }
                case .changePercent:
                    if pa.changePercent != pb.changePercent { return pa.changePercent < pb.changePercent }
                case .lastChange:
                    if pa.lastChange != pb.lastChange { return pa.lastChange < pb.lastChange }
                }
                // Tie-breakers: unit price, then price, then id (stable).
                if key != .unitPrice && pa.unitPrice != pb.unitPrice { return pa.unitPrice < pb.unitPrice }
                if pa.cents != pb.cents { return pa.cents < pb.cents }
                return a < b
            }
        }
        let missingStart = products.withUnsafeBufferPointer { ps in
            order.firstIndex { isMissing(ps[Int($0)]) } ?? order.count
        }
        let perm = Permutation(order: order, missingStart: missingStart)
        permutations.withLock { $0[key] = perm }
        return perm
    }
}
