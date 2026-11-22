import Foundation

/// All normalised search strings packed into one contiguous byte buffer
/// (`\0`-separated). The first query token is located with `memmem` sweeps over the
/// buffer (split across cores), every further token is only checked inside the
/// surviving candidates.
///
/// Storage is raw, immutable memory: hot loops never touch Swift array buffers, so
/// worker threads do not contend on reference counts.
public final class SearchIndex: @unchecked Sendable {
    /// `text[offsets[i] ..< offsets[i + 1] - 1]` is the normalised string of product `i`.
    private let text: UnsafeMutableBufferPointer<UInt8>
    private let offsets: UnsafeMutableBufferPointer<Int32>

    public var count: Int { offsets.count - 1 }
    public var byteCount: Int { text.count }

    init(strings: [[UInt8]]) {
        let total = strings.reduce(0) { $0 + $1.count + 1 }
        text = .allocate(capacity: max(total, 1))
        offsets = .allocate(capacity: strings.count + 1)
        var position = 0
        for (i, s) in strings.enumerated() {
            offsets[i] = Int32(position)
            s.withUnsafeBufferPointer { src in
                _ = UnsafeMutableBufferPointer(rebasing: text[position..<(position + src.count)]).initialize(from: src)
            }
            position += s.count
            text[position] = 0
            position += 1
        }
        if total == 0 { text[0] = 0 }
        offsets[strings.count] = Int32(position)
    }

    deinit {
        text.deallocate()
        offsets.deallocate()
    }

    /// A token copied into raw memory for the duration of one search.
    struct Needle {
        let pointer: UnsafeMutablePointer<UInt8>
        let count: Int
        init(_ bytes: [UInt8]) {
            pointer = .allocate(capacity: max(bytes.count, 1))
            pointer.initialize(from: bytes, count: bytes.count)
            count = bytes.count
        }
        func free() { pointer.deallocate() }
    }

    static let parallelism = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))

    /// Product ids whose text satisfies `query`, in ascending id order.
    /// - Parameter candidates: restrict to these ids (ascending), or `nil` for all products.
    public func search(_ query: SearchQuery, within candidates: [Int32]?) -> [Int32] {
        if query.positive.isEmpty && query.negative.isEmpty {
            return candidates ?? (0..<Int32(count)).map { $0 }
        }
        let positive = query.positive.map(Needle.init)
        let negative = query.negative.map(Needle.init)
        defer { (positive + negative).forEach { $0.free() } }
        let chunks = Self.parallelism

        if let candidates {
            return candidates.withUnsafeBufferPointer { ids in
                guard ids.count >= 16_384 else { return narrow(ids, positive[...], negative) }
                return Self.parallelMap(chunks: chunks) { chunk in
                    let lo = ids.count * chunk / chunks, hi = ids.count * (chunk + 1) / chunks
                    return narrow(UnsafeBufferPointer(rebasing: ids[lo..<hi]), positive[...], negative)
                }
            }
        }
        guard let first = positive.first else {
            let all = (0..<Int32(count)).map { $0 }
            return all.withUnsafeBufferPointer { narrow($0, [], negative) }
        }
        let rest = positive.dropFirst()
        return Self.parallelMap(chunks: chunks) { chunk in
            let lo = count * chunk / chunks, hi = count * (chunk + 1) / chunks
            let ids = scan(for: first, items: lo..<hi)
            if rest.isEmpty && negative.isEmpty { return ids }
            return ids.withUnsafeBufferPointer { narrow($0, rest, negative) }
        }
    }

    /// Runs `body` for each chunk concurrently and concatenates the results in chunk order.
    static func parallelMap(chunks: Int, _ body: (Int) -> [Int32]) -> [Int32] {
        if chunks == 1 { return body(0) }
        let parts = UnsafeMutableBufferPointer<[Int32]>.allocate(capacity: chunks)
        parts.initialize(repeating: [])
        defer { parts.deinitialize(); parts.deallocate() }
        withoutActuallyEscaping(body) { body in
            let box = UncheckedBox((parts, body))
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                box.value.0[chunk] = box.value.1(chunk)
            }
        }
        var result: [Int32] = []
        result.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { result.append(contentsOf: part) }
        return result
    }

    @inline(__always)
    private func contains(_ haystack: UnsafePointer<UInt8>, _ length: Int, _ needle: Needle) -> Bool {
        needle.count <= length && memmem(haystack, length, needle.pointer, needle.count) != nil
    }

    /// Keeps ids that contain every `positive` token and none of the `negative` ones.
    private func narrow(_ ids: UnsafeBufferPointer<Int32>, _ positive: ArraySlice<Needle>, _ negative: [Needle]) -> [Int32] {
        let base = UnsafePointer(text.baseAddress!)
        let offs = offsets.baseAddress!
        var result: [Int32] = []
        result.reserveCapacity(min(ids.count, 4096))
        positive.withContiguousStorageIfAvailable { pos in
            negative.withUnsafeBufferPointer { neg in
                outer: for id in ids {
                    let start = Int(offs[Int(id)])
                    let length = Int(offs[Int(id) + 1]) - start - 1
                    let haystack = base + start
                    for needle in pos where !contains(haystack, length, needle) { continue outer }
                    for needle in neg where contains(haystack, length, needle) { continue outer }
                    result.append(id)
                }
            }
        }
        return result
    }

    /// Single sweep over the bytes of `items` for `needle`; returns each matching id once.
    private func scan(for needle: Needle, items: Range<Int>) -> [Int32] {
        guard !items.isEmpty else { return [] }
        let base = UnsafePointer(text.baseAddress!)
        let offs = offsets.baseAddress!
        var result: [Int32] = []
        result.reserveCapacity(256)
        let end = Int(offs[items.upperBound])
        var position = Int(offs[items.lowerBound])
        var item = items.lowerBound
        while position < end, let hit = memmem(base + position, end - position, needle.pointer, needle.count) {
            let offset = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
            // Owning product: first k ≥ item with offsets[k + 1] > offset.
            var lo = item, hi = items.upperBound - 1
            while lo < hi {
                let mid = (lo + hi) >> 1
                if Int(offs[mid + 1]) <= offset { lo = mid + 1 } else { hi = mid }
            }
            item = lo
            result.append(Int32(item))
            position = Int(offs[item + 1]) // skip the rest of this product
            item += 1
            if item >= items.upperBound { break }
        }
        return result
    }

    // MARK: Relevance

    /// Simple relevance score: prefix match > word-start match > infix match, shorter titles win.
    func relevance(of id: Int32, query: SearchQuery) -> Int32 {
        do {
            let start = Int(offsets[Int(id)])
            let length = Int(offsets[Int(id) + 1]) - start - 1
            let haystack = UnsafePointer(text.baseAddress!) + start
            var score: Int32 = 0
            for token in query.positive {
                token.withUnsafeBytes { needle in
                    guard let hit = memmem(haystack, length, needle.baseAddress, needle.count) else { return }
                    let at = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - haystack
                    if at == 0 {
                        score += 40
                    } else {
                        let before = haystack[at - 1]
                        let isBoundary = !(before >= 97 && before <= 122) && !(before >= 48 && before <= 57) && before < 0x80
                        score += isBoundary ? 25 : 5
                    }
                    let end = at + needle.count
                    if end == length || haystack[end] == 0x20 { score += 10 } // whole word
                }
            }
            return score * 256 - Int32(min(length, 255))
        }
    }

    /// Byte-wise comparison of the normalised strings (fast, accent-insensitive name order).
    func compare(_ a: Int32, _ b: Int32) -> Int32 {
        do {
            let sa = Int(offsets[Int(a)]), la = Int(offsets[Int(a) + 1]) - sa - 1
            let sb = Int(offsets[Int(b)]), lb = Int(offsets[Int(b) + 1]) - sb - 1
            let c = memcmp(text.baseAddress! + sa, text.baseAddress! + sb, min(la, lb))
            if c != 0 { return c }
            return Int32(la - lb)
        }
    }
}

/// Carries non-Sendable scratch state into `concurrentPerform`, where each iteration
/// touches a disjoint slot only.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
