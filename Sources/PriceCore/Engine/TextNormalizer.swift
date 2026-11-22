import Foundation

/// Normalises text for search: lower-case, diacritics removed (ä→a, ß→ss, é→e), `,`→`.`,
/// whitespace collapsed. Works on UTF-8 bytes so the index can be scanned with `memmem`.
public enum TextNormalizer {
    /// Folding table for U+0080…U+024F (Latin-1 Supplement, Latin Extended-A/B).
    private static let latinTable: [[UInt8]] = (0x80...0x24F).map { value -> [UInt8] in
        guard let scalar = Unicode.Scalar(value) else { return [] }
        if value == 0xDF { return Array("ss".utf8) }
        let folded = String(Character(scalar))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        // Typographic spaces / control characters become plain spaces.
        if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control { return [0x20] }
        return Array(folded.utf8)
    }

    public static func normalize(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(string.utf8.count)
        append(string, to: &out)
        // Trim trailing space.
        while out.last == 0x20 { out.removeLast() }
        return out
    }

    /// Appends the normalised form of `string` to `out`, collapsing runs of whitespace.
    public static func append(_ string: String, to out: inout [UInt8]) {
        @inline(__always) func push(_ b: UInt8) {
            if b == 0x20 {
                if out.isEmpty || out.last == 0x20 { return }
            }
            out.append(b)
        }
        for scalar in string.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                var b = UInt8(v)
                switch b {
                case 65...90: b += 32
                case 44: b = 46 // , → .
                case 9, 10, 13, 0: b = 32
                default: break
                }
                push(b)
            } else if v <= 0x24F {
                for b in latinTable[Int(v - 0x80)] { push(b) }
            } else if scalar.properties.isWhitespace {
                push(0x20)
            } else if scalar.properties.generalCategory == .nonspacingMark {
                continue
            } else {
                for b in String(scalar.properties.lowercaseMapping).utf8 { push(b) }
            }
        }
    }
}

/// A parsed search query: all positive tokens must occur (any order), no negative token may occur.
public struct SearchQuery: Hashable, Sendable {
    public var positive: [[UInt8]]
    public var negative: [[UInt8]]

    public init(_ text: String) {
        var positive: [[UInt8]] = []
        var negative: [[UInt8]] = []
        for raw in TextNormalizer.normalize(text).split(separator: 0x20) {
            if raw.first == UInt8(ascii: "-") {
                let token = Array(raw.dropFirst())
                if !token.isEmpty, !negative.contains(token) { negative.append(token) }
            } else if !positive.contains(Array(raw)) {
                positive.append(Array(raw))
            }
        }
        // Drop tokens contained in other tokens ("mil milch" ≡ "milch"); longest first = most selective.
        positive.sort { $0.count > $1.count }
        self.positive = positive.enumerated().filter { idx, token in
            !positive[..<idx].contains { $0.count > token.count && $0.contains(token) }
        }.map(\.element)
        self.negative = negative
    }

    public var isEmpty: Bool { positive.isEmpty && negative.isEmpty }

    /// `true` if every result of `self` is guaranteed to be a result of `other`,
    /// i.e. `self` only narrows `other` – lets the engine search incrementally.
    public func refines(_ other: SearchQuery) -> Bool {
        guard Set(negative) == Set(other.negative) else { return false }
        return other.positive.allSatisfy { old in positive.contains { $0.contains(old) } }
    }
}

extension Array where Element == UInt8 {
    func contains(_ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > count { return false }
        return withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }
}
