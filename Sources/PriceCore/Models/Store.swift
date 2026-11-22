import Foundation

/// Austrian retail chains covered by heisse-preise.io.
/// The raw value is the compact on-disk / in-memory representation.
public enum Store: UInt8, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case billa, spar, hofer, lidl, penny, mpreis, dm, mueller, bipa, unimarkt

    public var id: UInt8 { rawValue }

    /// Key used by heisse-preise.io in feed file names and the `stores` lookup table.
    public var feedKey: String {
        switch self {
        case .billa: "billa"
        case .spar: "spar"
        case .hofer: "hofer"
        case .lidl: "lidl"
        case .penny: "penny"
        case .mpreis: "mpreis"
        case .dm: "dm"
        case .mueller: "mueller"
        case .bipa: "bipa"
        case .unimarkt: "unimarkt"
        }
    }

    public init?(feedKey: String) {
        guard let store = Store.allCases.first(where: { $0.feedKey == feedKey }) else { return nil }
        self = store
    }

    public var displayName: String {
        switch self {
        case .billa: "BILLA"
        case .spar: "SPAR"
        case .hofer: "HOFER"
        case .lidl: "Lidl"
        case .penny: "PENNY"
        case .mpreis: "MPREIS"
        case .dm: "dm"
        case .mueller: "Müller"
        case .bipa: "BIPA"
        case .unimarkt: "Unimarkt"
        }
    }

    /// Badge colours as 0xRRGGBB (background, foreground).
    public var badgeColors: (background: UInt32, foreground: UInt32) {
        switch self {
        case .billa: (0xFFD500, 0x1A1A1A)
        case .spar: (0x00843D, 0xFFFFFF)
        case .hofer: (0x10306E, 0xFFFFFF)
        case .lidl: (0x0050AA, 0xFFF000)
        case .penny: (0xCD1719, 0xFFFFFF)
        case .mpreis: (0x7A1F3D, 0xFFFFFF)
        case .dm: (0x00838F, 0xFFFFFF)
        case .mueller: (0xF07800, 0xFFFFFF)
        case .bipa: (0xE6007E, 0xFFFFFF)
        case .unimarkt: (0x8C6D1F, 0xFFFFFF)
        }
    }

    /// Discount own brands ("Eigenmarken"), lower-cased, as defined by heisse-preise.io.
    public var budgetBrands: [String] {
        switch self {
        case .billa: ["clever"]
        case .spar: ["s-budget"]
        case .hofer: ["milfina"]
        case .lidl: ["milbona", "alpengut", "cien", "livarno", "wiesentaler"]
        case .penny: ["bravo", "echt bio!", "san fabio", "federike", "blik", "berida", "today", "ich bin österreich"]
        case .mpreis: []
        case .dm: ["balea"]
        case .mueller: ["aveo"]
        case .bipa: ["babywell", "look by bipa", "bi care", "bi kids", "bi good", "bi life", "bi life dent"]
        case .unimarkt: ["jeden tag", "unipur"]
        }
    }

    /// heisse-preise.io matches *any* store's budget brand against every product name.
    public static let allBudgetBrands: [String] = {
        var seen = Set<String>()
        return Store.allCases.flatMap(\.budgetBrands).filter { seen.insert($0).inserted }
    }()

    /// Direct product page, mirroring `site/model/stores.js#getUrl` of heisse-preise.io.
    public func productURL(storeID: String, path: String) -> URL? {
        let string: String
        switch self {
        case .billa: string = path.isEmpty ? "" : "https://shop.billa.at/produkte/\(path)"
        case .spar: string = "https://www.interspar.at/shop/lebensmittel/p/\(storeID)"
        case .hofer: string = path.isEmpty ? "" : "https://www.roksh.at/hofer/produkte/\(path)"
        case .lidl: string = path.isEmpty ? "" : "https://www.lidl.at\(path)"
        case .penny: string = path.isEmpty ? "" : "https://www.penny.at/produkte/\(path)"
        case .mpreis: string = "https://www.mpreis.at/shop/p/\(storeID)"
        case .dm: string = "https://www.dm.at/product-p\(storeID).html"
        case .mueller: string = path.isEmpty ? "" : "https://www.mueller.at\(path)"
        case .bipa: string = path.isEmpty ? "" : "https://www.bipa.at\(path)"
        case .unimarkt: string = path.isEmpty ? "" : "https://shop.unimarkt.at\(path.hasPrefix("/") ? path : "/" + path)"
        }
        guard !string.isEmpty else { return nil }
        return URL(string: string)
            ?? URL(string: string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }

    public var shopDomain: String {
        switch self {
        case .billa: "billa.at"
        case .spar: "interspar.at"
        case .hofer: "hofer.at"
        case .lidl: "lidl.at"
        case .penny: "penny.at"
        case .mpreis: "mpreis.at"
        case .dm: "dm.at"
        case .mueller: "mueller.at"
        case .bipa: "bipa.at"
        case .unimarkt: "unimarkt.at"
        }
    }

    /// Site-restricted web search – works even when a product page moved.
    public func shopSearchURL(for name: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: "site:\(shopDomain) \(name)")]
        return components?.url
    }
}

/// Quick store selections offered in the sidebar.
public enum StorePreset: String, CaseIterable, Sendable, Identifiable {
    case all, discounters, rewe, spar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Alle"
        case .discounters: "Diskonter"
        case .rewe: "Rewe"
        case .spar: "SPAR"
        }
    }

    public var help: String {
        switch self {
        case .all: "Alle Händler"
        case .discounters: "HOFER, Lidl, PENNY"
        case .rewe: "BILLA, PENNY, BIPA"
        case .spar: "Nur SPAR"
        }
    }

    public var stores: Set<Store> {
        switch self {
        case .all: Set(Store.allCases)
        case .discounters: [.hofer, .lidl, .penny]
        case .rewe: [.billa, .penny, .bipa]
        case .spar: [.spar]
        }
    }
}
