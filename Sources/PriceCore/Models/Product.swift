import Foundation

/// Flat, immutable product record. All derived values are precomputed once at load time
/// so filtering, sorting and rendering never touch the price history.
public struct Product: Sendable, Identifiable {
    /// Index into `Catalog.products` (stable for the lifetime of a catalog).
    public let id: Int32
    public let store: Store
    public let storeID: String
    public let name: String
    public let urlPath: String
    public let categoryCode: UInt8
    public let unit: ProductUnit
    public let flags: Flags
    /// Package size in the feed unit (g, ml, Stk …); 0 if unknown.
    public let quantity: Double

    /// Current price in cents.
    public let cents: Int32
    /// Previous price (before the latest change) in cents; equals `cents` if there is no history.
    public let previousCents: Int32
    public let lowestCents: Int32
    public let highestCents: Int32
    /// Day of the most recent price change (= newest history entry).
    public let lastChange: Day
    /// Price per base unit (€/kg, €/L, €/Stk). `.infinity` if not computable.
    public let unitPrice: Double

    /// Location of this product's price history in `Catalog.history` (newest first).
    public let historyStart: Int32
    public let historyCount: Int32

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let unavailable = Flags(rawValue: 1 << 0)
        public static let weighted = Flags(rawValue: 1 << 1)
        public static let bio = Flags(rawValue: 1 << 2)
        public static let budget = Flags(rawValue: 1 << 3)
    }

    public init(
        id: Int32, store: Store, storeID: String, name: String, urlPath: String,
        categoryCode: UInt8, unit: ProductUnit, flags: Flags, quantity: Double,
        history: ArraySlice<PricePoint>, historyStart: Int32
    ) {
        self.id = id
        self.store = store
        self.storeID = storeID
        self.name = name
        self.urlPath = urlPath
        self.categoryCode = categoryCode
        self.unit = unit
        self.flags = flags
        self.quantity = quantity
        self.historyStart = historyStart
        self.historyCount = Int32(history.count)

        let current = history.first?.cents ?? 0
        cents = current
        previousCents = history.count > 1 ? history[history.startIndex + 1].cents : current
        lastChange = history.first?.day ?? 0
        var low = Int32.max, high = Int32.min
        for point in history {
            low = min(low, point.cents)
            high = max(high, point.cents)
        }
        lowestCents = history.isEmpty ? current : low
        highestCents = history.isEmpty ? current : high

        let baseQuantity = quantity * unit.baseFactor
        unitPrice = baseQuantity > 0 ? (Double(current) / 100) / baseQuantity : .infinity
    }

    // MARK: Convenience

    public var price: Double { Double(cents) / 100 }
    public var previousPrice: Double { Double(previousCents) / 100 }
    public var changeCents: Int32 { cents - previousCents }
    public var changePercent: Double {
        previousCents > 0 ? Double(cents - previousCents) / Double(previousCents) * 100 : 0
    }
    public var isReduced: Bool { cents < previousCents }
    public var isIncreased: Bool { cents > previousCents }
    public var isAllTimeLow: Bool { historyCount > 1 && cents <= lowestCents && highestCents > lowestCents }
    public var isBio: Bool { flags.contains(.bio) }
    public var isBudget: Bool { flags.contains(.budget) }
    public var isUnavailable: Bool { flags.contains(.unavailable) }
    public var hasUnitPrice: Bool { unitPrice.isFinite }
    public var baseQuantity: Double { quantity * unit.baseFactor }

    public var productURL: URL? { store.productURL(storeID: storeID, path: urlPath) }

    /// Stable identity across catalog reloads (used for the watchlist).
    public var key: ProductKey { ProductKey(store: store, storeID: storeID) }
}

public struct ProductKey: Hashable, Codable, Sendable {
    public let store: Store
    public let storeID: String
    public init(store: Store, storeID: String) {
        self.store = store
        self.storeID = storeID
    }
}
