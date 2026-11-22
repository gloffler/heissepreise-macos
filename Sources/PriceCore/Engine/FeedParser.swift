import Foundation

/// One product as it appears in a heisse-preise.io `latest-canonical.<store>.compressed.json` feed.
///
/// Feed layout (see `analysis.js#compress` / `site/model/items.js#decompress`):
/// ```
/// { "stores": [String], "n": Int, "dates": ["YYYYMMDD"],
///   "data": [ storeIdx, id, name, category, unavailable, numPrices,
///             (dateIdx, price) × numPrices, unit, quantity, isWeighted, bio, url, … ] }
/// ```
public struct FeedItem: Sendable {
    public var storeIndex: Int
    public var id: String
    public var name: String
    public var category: String?
    public var unavailable: Bool
    public var pricesStart: Int
    public var pricesCount: Int
    public var unit: String?
    public var quantity: Double
    public var weighted: Bool
    public var bio: Bool
    public var url: String
}

public struct FeedPrice: Sendable {
    public var dateIndex: Int32
    public var cents: Int32
}

public struct ParsedFeed: Sendable {
    public var stores: [String] = []
    public var dates: [Day] = []
    public var items: [FeedItem] = []
    public var prices: [FeedPrice] = []
}

public struct FeedParseError: Error, CustomStringConvertible, Sendable {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON-Fehler bei Byte \(offset): \(reason)" }
}

/// Hand-written, allocation-light JSON parser specialised for the compressed feed format.
/// Roughly an order of magnitude faster than `JSONSerialization` for these flat arrays,
/// because it never boxes values into `NSNumber`/`Any`.
public enum FeedParser {
    public static func parse(_ data: Data) throws -> ParsedFeed {
        try data.withUnsafeBytes { raw -> ParsedFeed in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw FeedParseError(offset: 0, reason: "leere Daten")
            }
            var cursor = JSONCursor(p: base, count: raw.count)
            return try cursor.parseFeed()
        }
    }
}

private let pow10Table: [Double] = (0...22).map { pow(10, Double($0)) }

struct JSONCursor {
    let p: UnsafePointer<UInt8>
    let count: Int
    var i = 0

    init(p: UnsafePointer<UInt8>, count: Int) {
        self.p = p
        self.count = count
    }

    // MARK: Feed structure

    mutating func parseFeed() throws -> ParsedFeed {
        var feed = ParsedFeed()
        try expect(UInt8(ascii: "{"))
        if consume(UInt8(ascii: "}")) { return feed }
        repeat {
            let key = try readString()
            try expect(UInt8(ascii: ":"))
            switch key {
            case "stores":
                feed.stores = try readStringArray()
            case "dates":
                feed.dates = try readStringArray().map { DayMath.parse($0) ?? 0 }
            case "data":
                try parseData(into: &feed)
            case "n":
                if let n = try readDoubleLike(), n > 0, n < 10_000_000 {
                    feed.items.reserveCapacity(Int(n))
                    feed.prices.reserveCapacity(Int(n) * 4)
                }
            default:
                try skipValue()
            }
        } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "}"))
        return feed
    }

    private mutating func parseData(into feed: inout ParsedFeed) throws {
        try expect(UInt8(ascii: "["))
        if consume(UInt8(ascii: "]")) { return }
        let comma = UInt8(ascii: ",")
        while true {
            let storeIndex = Int(try readDoubleLike() ?? -1); try expect(comma)
            let id = try readStringLike() ?? ""; try expect(comma)
            let name = try readStringLike() ?? ""; try expect(comma)
            let category = try readStringLike(); try expect(comma)
            let unavailable = (try readDoubleLike() ?? 0) == 1; try expect(comma)
            let numPrices = max(0, Int(try readDoubleLike() ?? 0)); try expect(comma)
            let pricesStart = feed.prices.count
            for _ in 0..<numPrices {
                let dateIndex = Int32(try readDoubleLike() ?? -1); try expect(comma)
                let price = try readDoubleLike() ?? 0; try expect(comma)
                feed.prices.append(FeedPrice(dateIndex: dateIndex, cents: Int32((price * 100).rounded())))
            }
            let unit = try readStringLike(); try expect(comma)
            let quantity = try readDoubleLike() ?? 0; try expect(comma)
            let weighted = (try readDoubleLike() ?? 0) == 1; try expect(comma)
            let bio = (try readDoubleLike() ?? 0) == 1; try expect(comma)
            let url = try readStringLike() ?? ""
            feed.items.append(FeedItem(
                storeIndex: storeIndex, id: id, name: name, category: category, unavailable: unavailable,
                pricesStart: pricesStart, pricesCount: numPrices, unit: unit, quantity: quantity,
                weighted: weighted, bio: bio, url: url
            ))
            if consume(comma) { continue }
            try expect(UInt8(ascii: "]"))
            return
        }
    }

    // MARK: Primitives

    @inline(__always)
    mutating func skipWhitespace() {
        while i < count {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { return }
        }
    }

    @inline(__always)
    mutating func consume(_ c: UInt8) -> Bool {
        skipWhitespace()
        if i < count && p[i] == c { i += 1; return true }
        return false
    }

    @inline(__always)
    mutating func expect(_ c: UInt8) throws {
        skipWhitespace()
        guard i < count, p[i] == c else {
            throw FeedParseError(offset: i, reason: "erwartet '\(Character(UnicodeScalar(c)))'")
        }
        i += 1
    }

    mutating func readStringArray() throws -> [String] {
        try expect(UInt8(ascii: "["))
        var result: [String] = []
        if consume(UInt8(ascii: "]")) { return result }
        repeat { result.append(try readStringLike() ?? "") } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "]"))
        return result
    }

    /// String, number (verbatim text) or `null`.
    mutating func readStringLike() throws -> String? {
        skipWhitespace()
        guard i < count else { throw FeedParseError(offset: i, reason: "unerwartetes Ende") }
        switch p[i] {
        case UInt8(ascii: "\""):
            return try readString()
        case UInt8(ascii: "n"):
            try readLiteral("null")
            return nil
        case UInt8(ascii: "t"):
            try readLiteral("true")
            return "true"
        case UInt8(ascii: "f"):
            try readLiteral("false")
            return "false"
        default:
            let start = i
            _ = try readNumber()
            return String(decoding: UnsafeBufferPointer(start: p + start, count: i - start), as: UTF8.self)
        }
    }

    /// Number, boolean, numeric string or `null`.
    mutating func readDoubleLike() throws -> Double? {
        skipWhitespace()
        guard i < count else { throw FeedParseError(offset: i, reason: "unerwartetes Ende") }
        switch p[i] {
        case UInt8(ascii: "n"):
            try readLiteral("null")
            return nil
        case UInt8(ascii: "t"):
            try readLiteral("true")
            return 1
        case UInt8(ascii: "f"):
            try readLiteral("false")
            return 0
        case UInt8(ascii: "\""):
            return Double(try readString().replacingOccurrences(of: ",", with: "."))
        default:
            return try readNumber()
        }
    }

    mutating func readLiteral(_ literal: StaticString) throws {
        let n = literal.utf8CodeUnitCount
        guard i + n <= count, memcmp(p + i, literal.utf8Start, n) == 0 else {
            throw FeedParseError(offset: i, reason: "ungültiges Literal")
        }
        i += n
    }

    @inline(__always)
    mutating func readNumber() throws -> Double {
        let start = i
        var negative = false
        if i < count && p[i] == UInt8(ascii: "-") { negative = true; i += 1 }
        var mantissa: UInt64 = 0
        var digits = 0
        var exponent = 0
        while i < count, case let d = p[i] &- 48, d < 10 {
            if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(d); if mantissa > 0 { digits += 1 } } else { exponent += 1 }
            i += 1
        }
        if i < count && p[i] == UInt8(ascii: ".") {
            i += 1
            while i < count, case let d = p[i] &- 48, d < 10 {
                if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(d); if mantissa > 0 { digits += 1 }; exponent -= 1 }
                i += 1
            }
        }
        if i < count && (p[i] == UInt8(ascii: "e") || p[i] == UInt8(ascii: "E")) {
            i += 1
            var expNegative = false
            if i < count && (p[i] == UInt8(ascii: "-") || p[i] == UInt8(ascii: "+")) {
                expNegative = p[i] == UInt8(ascii: "-"); i += 1
            }
            var e = 0
            while i < count, case let d = p[i] &- 48, d < 10 { e = min(e * 10 + Int(d), 10_000); i += 1 }
            exponent += expNegative ? -e : e
        }
        guard i > start + (negative ? 1 : 0) else { throw FeedParseError(offset: start, reason: "ungültige Zahl") }
        var value = Double(mantissa)
        if exponent < 0 {
            value = -exponent <= 22 ? value / pow10Table[-exponent] : value / pow(10, Double(-exponent))
        } else if exponent > 0 {
            value = exponent <= 22 ? value * pow10Table[exponent] : value * pow(10, Double(exponent))
        }
        return negative ? -value : value
    }

    mutating func readString() throws -> String {
        skipWhitespace()
        guard i < count, p[i] == UInt8(ascii: "\"") else { throw FeedParseError(offset: i, reason: "String erwartet") }
        i += 1
        let start = i
        // Fast path: no escapes.
        while i < count {
            let c = p[i]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(start: p + start, count: i - start), as: UTF8.self)
                i += 1
                return s
            }
            if c == UInt8(ascii: "\\") { break }
            i += 1
        }
        // Slow path with escape handling.
        var bytes = [UInt8](UnsafeBufferPointer(start: p + start, count: i - start))
        while i < count {
            let c = p[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: bytes, as: UTF8.self)
            }
            if c != UInt8(ascii: "\\") { bytes.append(c); i += 1; continue }
            i += 1
            guard i < count else { break }
            let e = p[i]; i += 1
            switch e {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "u"):
                var scalarValue = try readHex4()
                if (0xD800...0xDBFF).contains(scalarValue), i + 1 < count, p[i] == UInt8(ascii: "\\"), p[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let low = try readHex4()
                    scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                }
                let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: bytes.append(e) // \" \\ \/
            }
        }
        throw FeedParseError(offset: start, reason: "nicht abgeschlossener String")
    }

    private mutating func readHex4() throws -> UInt32 {
        guard i + 4 <= count else { throw FeedParseError(offset: i, reason: "ungültiges \\u-Escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = p[i]
            let d: UInt32
            switch c {
            case 48...57: d = UInt32(c - 48)
            case 65...70: d = UInt32(c - 55)
            case 97...102: d = UInt32(c - 87)
            default: throw FeedParseError(offset: i, reason: "ungültige Hex-Ziffer")
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }

    mutating func skipValue() throws {
        skipWhitespace()
        guard i < count else { return }
        switch p[i] {
        case UInt8(ascii: "\""): _ = try readString()
        case UInt8(ascii: "["), UInt8(ascii: "{"):
            let close = p[i] == UInt8(ascii: "[") ? UInt8(ascii: "]") : UInt8(ascii: "}")
            i += 1
            if consume(close) { return }
            repeat {
                if close == UInt8(ascii: "}") { _ = try readString(); try expect(UInt8(ascii: ":")) }
                try skipValue()
            } while consume(UInt8(ascii: ","))
            try expect(close)
        default: _ = try readStringLike()
        }
    }
}
