import Foundation

// MARK: - Day

/// Calendar day as days since 1970-01-01 (UTC). Compact and trivially comparable.
public typealias Day = Int32

public enum DayMath {
    /// Howard Hinnant's `days_from_civil`.
    @inline(__always)
    public static func day(year: Int, month: Int, day: Int) -> Day {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Day(era * 146_097 + doe - 719_468)
    }

    /// Parses `YYYYMMDD` or `YYYY-MM-DD`.
    public static func parse(_ string: String) -> Day? {
        let digits = string.utf8.filter { $0 >= 48 && $0 <= 57 }.map { Int($0 - 48) }
        guard digits.count == 8 else { return nil }
        let y = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let m = digits[4] * 10 + digits[5]
        let d = digits[6] * 10 + digits[7]
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        return day(year: y, month: m, day: d)
    }

    /// Noon UTC of the day, so that local formatting never shifts the calendar date in Europe.
    public static func date(_ day: Day) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
    }

    public static func day(of date: Date) -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public static var today: Day { day(of: Date()) }
}

// MARK: - Unit

/// Unit of the package size as delivered by heisse-preise.io.
public enum ProductUnit: UInt8, Sendable, Codable, CaseIterable {
    case gram, milliliter, piece, washLoads, centimeter, unknown

    public init(raw: String?) {
        switch raw?.lowercased() {
        case "g", "kg": self = .gram
        case "ml", "l": self = .milliliter
        case "stk", "stück": self = .piece
        case "wg": self = .washLoads
        case "cm", "m": self = .centimeter
        default: self = .unknown
        }
    }

    /// Factor to convert a quantity into the base unit used for the unit price (kg, L, Stk …).
    public var baseFactor: Double {
        switch self {
        case .gram, .milliliter: 0.001
        case .centimeter: 0.01
        default: 1
        }
    }

    /// Label of the base unit (`€/kg`, `€/L`, …).
    public var baseLabel: String {
        switch self {
        case .gram: "kg"
        case .milliliter: "L"
        case .piece, .unknown: "Stk"
        case .washLoads: "WG"
        case .centimeter: "m"
        }
    }

    public var unitFilter: UnitFilter {
        switch self {
        case .gram: .weight
        case .milliliter: .volume
        case .piece, .unknown: .piece
        case .washLoads, .centimeter: .other
        }
    }
}

/// Coarse unit classes for the quantity filter.
public enum UnitFilter: String, CaseIterable, Sendable, Codable, Identifiable {
    case any, weight, volume, piece, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: "Alle"
        case .weight: "kg"
        case .volume: "L"
        case .piece: "Stk"
        case .other: "Andere"
        }
    }

    public var quantityLabel: String {
        switch self {
        case .weight: "kg"
        case .volume: "L"
        case .piece: "Stk"
        case .any, .other: "Einh."
        }
    }
}

// MARK: - Price history

/// One entry of a product's price history (8 bytes).
public struct PricePoint: Sendable, Hashable {
    public var day: Day
    public var cents: Int32

    public init(day: Day, cents: Int32) {
        self.day = day
        self.cents = cents
    }

    public var euros: Double { Double(cents) / 100 }
    public var date: Date { DayMath.date(day) }
}

// MARK: - Category

/// Two-level category system of heisse-preise.io (codes like `"13"` or `"4C"`).
public struct ProductCategory: Sendable, Identifiable {
    public let index: Int
    public let name: String
    public let subcategories: [String]
    public var id: Int { index }

    /// Packed code: high nibble = main category, low nibble = subcategory.
    public static func code(_ main: Int, _ sub: Int) -> UInt8 { UInt8((main & 0xF) << 4 | (sub & 0xF)) }
    public static func main(of code: UInt8) -> Int { Int(code >> 4) }
    public static func sub(of code: UInt8) -> Int { Int(code & 0xF) }

    public static let unknownCode: UInt8 = code(all.count - 1, 0)

    /// Decodes the two-character code from the feed.
    public static func decode(_ raw: String?) -> UInt8 {
        guard let raw, raw.utf8.count >= 2 else { return unknownCode }
        let bytes = Array(raw.utf8.prefix(2))
        func value(_ b: UInt8) -> Int {
            if b >= 48 && b <= 57 { return Int(b - 48) }
            if b >= 65 && b <= 90 { return Int(b - 65) + 10 }
            if b >= 97 && b <= 122 { return Int(b - 97) + 10 }
            return -1
        }
        let i = value(bytes[0]), j = value(bytes[1])
        guard i >= 0, i < all.count, j >= 0, j < all[i].subcategories.count else { return unknownCode }
        return code(i, j)
    }

    public static func names(for code: UInt8) -> (main: String, sub: String) {
        let category = all[min(main(of: code), all.count - 1)]
        let s = sub(of: code)
        return (category.name, s < category.subcategories.count ? category.subcategories[s] : "Unbekannt")
    }

    /// Mirrors `site/model/categories.js`.
    public static let all: [ProductCategory] = [
        ("🍌 Obst & Gemüse", ["Obst", "Gemüse", "Salate", "Trockenfrüchte & Nüsse"]),
        ("🍞 Brot & Gebäck", ["Aufbackbrötchen & Toast", "Brot & Gebäck", "Knäckebrot & Zwieback", "Kuchen & Co.", "Semmelwürfel & Brösel"]),
        ("🥤 Getränke", ["Alkoholfreie Getränke", "Bier & Radler", "Kaffee, Tee & Co.", "Sekt & Champagner", "Spirituosen", "Wein", "Mineralwasser"]),
        ("🥛 Kühlwaren", ["Fertiggerichte", "Eier", "Fleisch", "Käse, Aufstriche & Salate", "Milchprodukte", "Feinkostplatten & Brötchen", "Blätterteig, Strudelteig", "Wurst, Schinken & Speck", "Feinkost", "Fisch", "Unbekannt", "Vegetarisch, Tofu, Soja & Co"]),
        ("🧊 Tiefkühl", ["Eis", "Unbekannt", "Fertiggerichte", "Fisch & Garnelen", "Gemüse, Kräuter & Obst", "Pommes Frites & Co.", "Pizza & Baguette", "Desserts & Früchte"]),
        ("🌾 Grundnahrungsmittel", ["Asia & Mexican Produkte", "Baby", "Backen", "Essig & Öl", "Fertiggerichte", "Gewürze & Würzmittel", "Honig, Marmelade & Co.", "Konserven & Sauerwaren", "Kuchen & Co.", "Mehl & Getreideprodukte", "Müsli & Cerealien", "Reis, Teigwaren & Sugo", "Saucen & Dressings", "Spezielle Ernährung", "Zucker & Süßstoffe", "Fixprodukte"]),
        ("🍫 Süßes & Salziges", ["Biskotten & Eiswaffeln", "Für kluge Naschkatzen", "Müsliriegel", "Chips & Co.", "Süßes"]),
        ("🧴 Pflege", ["Baby", "Damenhygiene", "Deodorants", "Haarpflege & Haarfarben", "Pflaster & Verbandsmaterial", "Haut- & Lippenpflege", "Mund- & Zahnhygiene", "Rasierbedarf", "Seife & Duschbäder", "Sonnen- & Gelsenschutzmittel", "Verhütungsmittel", "Fußpflege", "Strumpfhosen & Socken"]),
        ("🧹 Haushalt", ["Büro- & Schulartikel", "Garten", "Kleben & Befestigen", "Küchenartikel", "Küchenrollen & WC-Papier", "Lampen & Batterien", "Müllsäcke, Gefrierbeutel & Co.", "Raumsprays & Kerzen", "Reinigen & Pflegen", "Taschentücher & Servietten", "Waschmittel & Weichspüler", "Schuhpflege", "Kunststoffbehälter", "Insektenschutz", "Spielwaren", "Hygiene-Schutzartikel"]),
        ("🐾 Haustier", ["Hunde", "Katzen", "Kleintiere", "Vögel"]),
        ("❔ Unbekannt", ["Unbekannt"]),
    ].enumerated().map { ProductCategory(index: $0.offset, name: $0.element.0, subcategories: $0.element.1) }
}
